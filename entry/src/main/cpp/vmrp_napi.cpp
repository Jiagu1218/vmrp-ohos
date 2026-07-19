/*
 * vmrp_napi.cpp - NAPI 桥接主入口。
 *
 * 把 VmrpEngine/VmrpRenderer/VmrpAudio 整合为 ArkTS 可调用的 NAPI 模块，
 * 采用官方范式5（NDK 节点创建 + OH_ArkUI_SurfaceHolder）管理 XComponent Surface 生命周期。
 *
 * 为什么用 NDK 节点创建范式：
 *   声明式 XComponent + getAttachedFrameNodeById 拿到的 handle 不是 NDK XComponent 节点，
 *   SurfaceHolder_Create 返回 rc=401（PARAM_INVALID）。只有 native 侧 createNode(ARKUI_NODE_XCOMPONENT)
 *   产出的节点才是真正的 NDK XComponent 节点，SurfaceHolder 才接受。
 *
 * 绑定流程：
 *   - ArkTS: ContentSlot(nodeContent) 占位渲染区；aboutToAppear 调 createSurfaceNode(nodeContent)。
 *   - native createSurfaceNode: NodeContent→handle → RegisterCallback(ON_ATTACH_TO_WINDOW)。
 *   - ON_ATTACH_TO_WINDOW 回调里: createNode(ARKUI_NODE_XCOMPONENT) + 设尺寸 + SurfaceHolder_Create
 *     + SurfaceCallback + OnFrameCallback + NODE_TOUCH_EVENT + NodeContent_AddNode。
 *
 * Surface 生命周期（callback-object 模式）：
 *   - OnSurfCreated(holder)：GetNativeWindow → renderer.OnSurfaceCreated(window)；
 *   - OnSurfChanged(holder, w, h)：用回调给的物理像素尺寸 RebuildSurface；
 *   - OnSurfDestroyed(holder)：renderer.OnSurfaceDestroyed。
 *
 * 触摸：native NODE_TOUCH_EVENT 回调里 PointerEvent_GetX/Y + GetAction → SendEvent（不经 ArkTS）。
 *
 * 线程：EGL 渲染在 XComponent 帧回调线程，避免 EGL surface 跨线程 swap。
 */
#include "napi/native_api.h"
#include "vmrp_engine.h"
#include "vmrp_renderer.h"
#include "vmrp_audio.h"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <arkui/native_interface.h>
#include <arkui/native_node.h>
#include <arkui/native_node_napi.h>
#include <arkui/ui_input_event.h>
#include <hilog/log.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#undef LOG_TAG
#define LOG_TAG "vmrp_napi"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

namespace {
// 全局状态：渲染器与音频在 XComponent 回调线程上创建/销毁。
VmrpRenderer g_renderer;
VmrpAudio    g_audio;
std::mutex   g_render_mtx;

// 定时器驱动线程：仅请求渲染 + 检测引擎退出（timer/event 由 vmrp 内部 worker 自驱）。
std::thread  g_timer_thread;
std::atomic<bool> g_timer_running{false};
std::atomic<bool> g_engine_running{false};

// 编辑回调：把编辑状态通知到 ArkTS（通过 napi_threadsafe_function）。
napi_threadsafe_function g_edit_tsfn = nullptr;

// 触摸事件码由 skyengine_api.h 宏提供。
} // namespace

#include "skyengine_api.h"

// 这几个函数在全局命名空间定义（无 namespace），供本文件各处调用。
void TryRender();
void TryRenderForce(); // 不管 dirty 都渲染一帧（确保持续上屏）
void NotifyEditIfNeeded();
void RequestRender();

// NDK 节点 API（@since 12）+ SurfaceHolder（@since 19）。
// 渲染必须在 XComponent 的渲染线程（帧回调线程）执行，否则 EGL surface 跨
// 线程 swap 会报 EGL_BAD_SURFACE（window surface 与创建它的 XComponent 绑定）。
static ArkUI_NativeNodeAPI_1 *g_node_api = nullptr;   // 懒加载，createSurfaceNode 时初始化
static ArkUI_NodeContentHandle g_content = nullptr;   // ArkTS ContentSlot 对应的 NodeContent
static ArkUI_NodeHandle g_xc_node = nullptr;          // native createNode(ARKUI_NODE_XCOMPONENT) 产物
static OH_ArkUI_SurfaceHolder *g_holder = nullptr;
static OH_ArkUI_SurfaceCallback *g_surf_cb = nullptr;
// 渲染请求标志：timer 线程驱动引擎后置位，帧回调线程消费并渲染。
std::atomic<bool> g_need_render{false};

// 前向声明（定义在 createSurfaceNode 之后，此处供 OnSurf* 早引用）。
static void OnNodeTouchEvent(ArkUI_NodeEvent *event);

// 帧回调：在 XComponent 渲染线程（API 20 OH_ArkUI_XComponent_RegisterOnFrameCallback 注册）执行。
// 这是渲染 EGL surface 的正确线程。timer 线程只置 g_need_render，不直接渲染。
static void OnFrameCallback(ArkUI_NodeHandle node, uint64_t timestamp, uint64_t targetTimestamp) {
    (void)node; (void)timestamp; (void)targetTimestamp;
    // 引擎运行时每帧都渲染并 swap：XComponent 的 EGL window surface 是双缓冲，
    // 需要持续 eglSwapBuffers 才能维持画面显示。dsm_gm 等静态画面画完一帧后不再
    // dirty，但 window surface 必须持续 swap 否则内容会被回收导致黑屏。
    if (g_engine_running.load()) {
        TryRenderForce();
    } else if (g_need_render.exchange(false)) {
        TryRender();
    }
}

// ---- SurfaceHolder 回调（callback-object 模式）----
// Created：从 holder 取 native window 建 EGL surface（占位，最终尺寸由 Changed 兜底）。
static void OnSurfCreated(OH_ArkUI_SurfaceHolder *holder) {
    OHNativeWindow *window = OH_ArkUI_XComponent_GetNativeWindow(holder);
    int32_t w = VmrpEngine::Instance().ScreenWidth();
    int32_t h = VmrpEngine::Instance().ScreenHeight();
    if (w <= 0) w = 240;
    if (h <= 0) h = 320;
    std::lock_guard<std::mutex> lk(g_render_mtx);
    g_renderer.OnSurfaceCreated(window);
    LOGI("OnSurfCreated screen=%{public}dx%{public}d, window=%{public}p", w, h, (void *)window);
}

// Changed：回调直接给物理像素尺寸，省掉 GetXComponentSize，直接 RebuildSurface 纠正
// Created 时可能拿到的布局中间态尺寸。
static void OnSurfChanged(OH_ArkUI_SurfaceHolder *holder, uint64_t width, uint64_t height) {
    (void)holder;
    if (width == 0 || height == 0) return;
    std::lock_guard<std::mutex> lk(g_render_mtx);
    g_renderer.RebuildSurface((int32_t)width, (int32_t)height);
    LOGI("OnSurfChanged rebuilt to %{public}llux%{public}llu",
         (unsigned long long)width, (unsigned long long)height);
}

static void OnSurfDestroyed(OH_ArkUI_SurfaceHolder *holder) {
    (void)holder;
    std::lock_guard<std::mutex> lk(g_render_mtx);
    g_renderer.OnSurfaceDestroyed();
    LOGI("OnSurfDestroyed");
}

// 若屏幕脏则渲染一帧。由 XComponent 帧回调（渲染线程）调用。
void TryRender() {
    if (!g_engine_running.load()) return;
    if (!VmrpEngine::Instance().ScreenDirty()) return;
    std::lock_guard<std::mutex> lk(g_render_mtx);
    if (!g_renderer.Ready()) return;
    const uint8_t *rgba = VmrpEngine::Instance().ScreenRgbaBuffer();
    int32_t sw = VmrpEngine::Instance().ScreenWidth();
    int32_t sh = VmrpEngine::Instance().ScreenHeight();
    g_renderer.Render(rgba, sw, sh);
}

// 在非渲染线程（timer/key/touch）请求渲染：置标志，由帧回调线程消费。
void RequestRender() { g_need_render.store(true); }

// 强制渲染：不检查 dirty，每帧都上传纹理并 swap。
// EGL window surface 是双缓冲，需持续 eglSwapBuffers 维持显示；
// 静态画面画完一帧后不再 dirty，但仍需每帧 swap 保持上屏。
void TryRenderForce() {
    if (!g_engine_running.load()) return;
    std::lock_guard<std::mutex> lk(g_render_mtx);
    if (!g_renderer.Ready()) return;
    const uint8_t *rgba = VmrpEngine::Instance().ScreenRgbaBuffer();
    int32_t sw = VmrpEngine::Instance().ScreenWidth();
    int32_t sh = VmrpEngine::Instance().ScreenHeight();
    g_renderer.Render(rgba, sw, sh);
}

// 渲染驱动循环。
// skyengine_api.c 在 VMRP_API_ASYNC_RUNNER=1 下采用 async worker 模型：skyengine_api_start
// 成功后自动起 worker 线程自驱 timer()/event()。本循环不再调 StepTimer()，
// 只做三件事：1) 周期请求渲染；2) 检测引擎退出；3) 轮询 motion/shake。
static void TimerLoop() {
    LOGI("timer loop started (async: render-only)");
    while (g_timer_running.load()) {
        if (!g_engine_running.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }
        RequestRender();
        NotifyEditIfNeeded();
        // 轮询上游 motion/shake：take_shake 驱动振动器，motion_active 启停传感器
        VmrpEngine::Instance().PollMotionShake();
        if (!VmrpEngine::Instance().IsRunning()) {
            g_engine_running.store(false);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
    }
    LOGI("timer loop exited");
}

// 编辑通知：状态从无到有时回调 ArkTS，并携带待编辑的原文本用于回显。
static std::atomic<bool> g_edit_notified{false};
void NotifyEditIfNeeded() {
    bool active = VmrpEngine::Instance().EditActive();
    if (active && !g_edit_notified.exchange(true)) {
        if (g_edit_tsfn) {
            // 取出 MRP 请求编辑时的初始文本，堆分配后跨线程传给 CallJsEdit（它会释放）。
            std::string *text = new std::string(VmrpEngine::Instance().GetEditText());
            napi_acquire_threadsafe_function(g_edit_tsfn);
            napi_call_threadsafe_function(g_edit_tsfn, text, napi_tsfn_nonblocking);
            napi_release_threadsafe_function(g_edit_tsfn, napi_tsfn_release);
        }
    } else if (!active) {
        g_edit_notified.store(false);
    }
}

// ---- NAPI 导出方法 ----

// loadLib(soPath): dlopen libvmrp.so 并解析符号。
static napi_value LoadLib(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char path[1024] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], path, sizeof(path), &len);
    bool ok = VmrpEngine::Instance().Load(path);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

// init(width, height): 初始化屏幕缓冲。
static napi_value InitEngine(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t w = 240, h = 320;
    napi_get_value_int32(env, args[0], &w);
    napi_get_value_int32(env, args[1], &h);
    int r = VmrpEngine::Instance().Init(w, h);
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// setWorkDir(dir): 设置 vmrp 工作目录。
static napi_value SetWorkDir(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char dir[1024] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], dir, sizeof(dir), &len);
    int r = VmrpEngine::Instance().SetWorkDir(dir);
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// setMemory(memoryMb): 设置 MRP 可见内存（MB），允许值 1/2/4/6/8/16，须在 start 前调用。
static napi_value SetMemory(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t memMb = 1;
    napi_get_value_int32(env, args[0], &memMb);
    int r = skyengine_api_set_memory(memMb);
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// start(mrpPath, ext, entry): 启动 MRP。成功后启动定时器线程和音频。
static napi_value StartEngine(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char mrp[1024] = {0}, ext[128] = {0}, entry[64] = {0};
    size_t l = 0;
    napi_get_value_string_utf8(env, args[0], mrp, sizeof(mrp), &l);
    napi_get_value_string_utf8(env, args[1], ext, sizeof(ext), &l);
    napi_get_value_string_utf8(env, args[2], entry, sizeof(entry), &l);

    // 注册音频暂停回调：dsm.c media_pause_cb 可通过此函数暂停/恢复 OHAudio renderer。
    VmrpEngine::Instance().SetAudioPauseFn([](bool pause) {
        if (pause) g_audio.Pause(); else g_audio.Resume();
    });

    // 注册音量回调：dsm.c mr_plat(1302,level) 通过 skyengine_api_set_volume 触发。
    VmrpEngine::Instance().SetVolumeFn([](int level) {
        g_audio.SetVolume(level);
    });

    int r = VmrpEngine::Instance().Start(mrp, ext, entry);
    if (r == 0 && VmrpEngine::Instance().IsRunning()) {
        g_engine_running.store(true);
        g_audio.Start(VmrpEngine::Instance().AudioSampleRate(),
                      VmrpEngine::Instance().AudioChannels());
        if (!g_timer_running.exchange(true)) {
            if (g_timer_thread.joinable()) g_timer_thread.join();
            g_timer_thread = std::thread(TimerLoop);
        }
    }
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// stop(): 停止引擎、音频、定时器。
static napi_value StopEngine(napi_env env, napi_callback_info info) {
    (void)env; (void)info;
    g_engine_running.store(false);
    g_timer_running.store(false);
    if (g_timer_thread.joinable()) g_timer_thread.join();
    g_audio.Stop();
    VmrpEngine::Instance().Destroy();
    return nullptr;
}

// sendKey(type, key): 发送按键事件（press/release）。
static napi_value SendKey(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t type = 0, key = 0;
    napi_get_value_int32(env, args[0], &type);
    napi_get_value_int32(env, args[1], &key);
    int r = VmrpEngine::Instance().SendEvent(type, key, 0);
    RequestRender();
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// sendMotion(x, y, z): 发送重力感应数据（mG 单位）。
// 不调 RequestRender()——传感器高频，MRP 自身 timer 驱动重绘。
static napi_value SendMotion(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t x = 0, y = 0, z = 0;
    napi_get_value_int32(env, args[0], &x);
    napi_get_value_int32(env, args[1], &y);
    napi_get_value_int32(env, args[2], &z);
    VmrpEngine::Instance().SendMotion(x, y, z);
    return nullptr;
}

// setMotionSensitivity(sensitivity: number)
static napi_value SetMotionSensitivity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double val = 1.0;
    napi_get_value_double(env, args[0], &val);
    VmrpEngine::Instance().SetMotionSensitivity(static_cast<float>(val));
    return nullptr;
}

// setShakeIntensity(level: number) — 0=轻, 1=中, 2=强
static napi_value SetShakeIntensity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t level = 1;
    napi_get_value_int32(env, args[0], &level);
    VmrpEngine::Instance().SetShakeIntensity(level);
    return nullptr;
}

// setDisplayFilter(filterType, screenEffect, screenEffectStrength, brightness, contrast, saturation, subpixelRender, gammaCorrect, dither)
// filterType: 0=Nearest,1=Bilinear,2=EPX,3=xBRZ,4=FSRCNNX
// screenEffect: 0=关闭,1=完整CRT,2=LCD网格,3=仅扫描线
// subpixelRender: 0=关,1=开; gammaCorrect: 0=关,1=开; dither: 0=关,1=开
static napi_value SetDisplayFilter(napi_env env, napi_callback_info info) {
    size_t argc = 9;
    napi_value args[9];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t filterType = 0;
    int32_t screenEffect = 0;
    double screenEffectStrength = 0.5;
    double brightness = 0.0;
    double contrast = 1.0;
    double saturation = 1.0;
    int32_t subpixelRender = 0;
    int32_t gammaCorrect = 1;
    int32_t dither = 1;
    if (argc > 0) napi_get_value_int32(env, args[0], &filterType);
    if (argc > 1) napi_get_value_int32(env, args[1], &screenEffect);
    if (argc > 2) napi_get_value_double(env, args[2], &screenEffectStrength);
    if (argc > 3) napi_get_value_double(env, args[3], &brightness);
    if (argc > 4) napi_get_value_double(env, args[4], &contrast);
    if (argc > 5) napi_get_value_double(env, args[5], &saturation);
    if (argc > 6) napi_get_value_int32(env, args[6], &subpixelRender);
    if (argc > 7) napi_get_value_int32(env, args[7], &gammaCorrect);
    if (argc > 8) napi_get_value_int32(env, args[8], &dither);
    g_renderer.SetDisplayFilter(filterType, screenEffect,
                                static_cast<float>(screenEffectStrength),
                                static_cast<float>(brightness),
                                static_cast<float>(contrast),
                                static_cast<float>(saturation),
                                subpixelRender, gammaCorrect, dither);
    return nullptr;
}

// startDsmB(entry: string) — 外部移植接口 mr_start_dsmB
static napi_value StartDsmB(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char entry[512] = "*A";
    size_t l = 0;
    if (argc > 0) napi_get_value_string_utf8(env, args[0], entry, sizeof(entry), &l);
    int r = VmrpEngine::Instance().StartDsmB(entry);
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// startDsmC(entry: string) — 外部移植接口 mr_start_dsmC
static napi_value StartDsmC(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char entry[512] = "*A";
    size_t l = 0;
    if (argc > 0) napi_get_value_string_utf8(env, args[0], entry, sizeof(entry), &l);
    int r = VmrpEngine::Instance().StartDsmC(entry);
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// startDsmEx(path: string, entry?: string) — 外部移植接口 mr_start_dsm_ex
static napi_value StartDsmEx(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char path[512] = "";
    char entry[512] = "";
    size_t l = 0;
    napi_get_value_string_utf8(env, args[0], path, sizeof(path), &l);
    if (argc > 1 && args[1]) napi_get_value_string_utf8(env, args[1], entry, sizeof(entry), &l);
    int r = VmrpEngine::Instance().StartDsmEx(path, entry);
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// submitEdit(text) / cancelEdit()
static napi_value SubmitEdit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char text[4096] = {0};
    size_t l = 0;
    napi_get_value_string_utf8(env, args[0], text, sizeof(text), &l);
    int r = VmrpEngine::Instance().SetEditText(text);
    g_edit_notified.store(false);
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

static napi_value CancelEdit(napi_env env, napi_callback_info info) {
    (void)env; (void)info;
    int r = VmrpEngine::Instance().CancelEdit();
    g_edit_notified.store(false);
    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

// isRunning()
static napi_value IsRunning(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result;
    napi_get_boolean(env, VmrpEngine::Instance().IsRunning(), &result);
    return result;
}

// mediaPause(): 暂停音频渲染(不清 PCM,可恢复)
// 同时暂停 OHAudio renderer 停止拉流回调,避免空转。
static napi_value MediaPause(napi_env env, napi_callback_info info) {
    (void)env; (void)info;
    VmrpEngine::Instance().MediaPause();
    g_audio.Pause();
    return nullptr;
}

// mediaResume(): 恢复音频渲染
// 同时恢复 OHAudio renderer 拉流回调。
static napi_value MediaResume(napi_env env, napi_callback_info info) {
    (void)env; (void)info;
    VmrpEngine::Instance().MediaResume();
    g_audio.Resume();
    return nullptr;
}

// ---- 编辑回调 threadsafe function ----
// data 是堆分配的 std::string（待编辑原文本），CallJs 转成 napi_string 传给 ArkTS 回调后释放。
static void CallJsEdit(napi_env env, napi_value js_cb, void * /*context*/, void *data) {
    if (env && js_cb) {
        std::unique_ptr<std::string> text(static_cast<std::string *>(data));
        napi_value undefined, arg;
        napi_get_undefined(env, &undefined);
        napi_create_string_utf8(env, text ? text->c_str() : "",
                                text ? text->size() : 0, &arg);
        // ArkTS 回调签名: (editText: string) => void
        napi_call_function(env, undefined, js_cb, 1, &arg, nullptr);
    } else if (data) {
        // env 不可用时仍要释放 data 避免泄漏。
        delete static_cast<std::string *>(data);
    }
}

// setEditCallback(cb): 注册编辑状态回调。
static napi_value SetEditCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_edit_tsfn) {
        napi_release_threadsafe_function(g_edit_tsfn, napi_tsfn_release);
        g_edit_tsfn = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, "vmrp_edit_cb", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, args[0], nullptr, name, 0, 1, nullptr,
                                    nullptr, nullptr, CallJsEdit, &g_edit_tsfn);
    return nullptr;
}

// native 触摸事件回调：PointerEvent_GetX/Y + GetAction → SendEvent（不经 ArkTS）。
static void OnNodeTouchEvent(ArkUI_NodeEvent *event) {
    const ArkUI_UIInputEvent *input = OH_ArkUI_NodeEvent_GetInputEvent(event);
    if (input == nullptr) return;
    if (OH_ArkUI_UIInputEvent_GetType(input) != ARKUI_UIINPUTEVENT_TYPE_TOUCH) return;

    float x = OH_ArkUI_PointerEvent_GetX(input);
    float y = OH_ArkUI_PointerEvent_GetY(input);
    int32_t sw = VmrpEngine::Instance().ScreenWidth();
    int32_t sh = VmrpEngine::Instance().ScreenHeight();
    if (sw <= 0) sw = 240;
    if (sh <= 0) sh = 320;
    // XComponent 节点 240x320 vp，PointerEvent 坐标相对其左上角，与 MRP 屏幕 1:1。
    int32_t mx = std::max(0, std::min(sw - 1, static_cast<int32_t>(x)));
    int32_t my = std::max(0, std::min(sh - 1, static_cast<int32_t>(y)));

    int code = -1;
    switch (OH_ArkUI_UIInputEvent_GetAction(input)) {
        case UI_TOUCH_EVENT_ACTION_DOWN: code = VMRP_MOUSE_DOWN; break;
        case UI_TOUCH_EVENT_ACTION_UP:   code = VMRP_MOUSE_UP;   break;
        case UI_TOUCH_EVENT_ACTION_MOVE: code = VMRP_MOUSE_MOVE; break;
        default: break;
    }
    if (code >= 0) {
        VmrpEngine::Instance().SendEvent(code, mx, my);
        RequestRender();
    }
}

// createSurfaceNode(nodeContent): ArkTS 在 aboutToAppear 时调用（UI 线程）。
// 同步创建 XComponent 节点 + SurfaceHolder + 挂到 NodeContent（按官方 ContentSlot 范式）。
// 范式5核心：native createNode(ARKUI_NODE_XCOMPONENT) 产出真正的 NDK XComponent 节点，
// SurfaceHolder_Create 才接受它（声明式 XComponent handle 不被接受，rc=401）。
static napi_value CreateSurfaceNode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        LOGE("createSurfaceNode: missing nodeContent arg");
        return nullptr;
    }

    int32_t r = OH_ArkUI_GetNodeContentFromNapiValue(env, args[0], &g_content);
    if (r != ARKUI_ERROR_CODE_NO_ERROR || g_content == nullptr) {
        LOGE("GetNodeContentFromNapiValue failed: rc=%{public}d", r);
        return nullptr;
    }
    LOGI("createSurfaceNode: content=%{public}p", (void *)g_content);

    // 懒加载 nodeAPI。
    if (g_node_api == nullptr) {
        OH_ArkUI_GetModuleInterface(ARKUI_NATIVE_NODE, ArkUI_NativeNodeAPI_1, g_node_api);
    }
    if (g_node_api == nullptr) {
        LOGE("GetModuleInterface(ARKUI_NATIVE_NODE) returned null");
        return nullptr;
    }

    // 1) 创建 XComponent 节点 + 设尺寸 240x320（vp，与 MRP 屏幕一致）。
    g_xc_node = g_node_api->createNode(ARKUI_NODE_XCOMPONENT);
    if (g_xc_node == nullptr) {
        LOGE("createNode(ARKUI_NODE_XCOMPONENT) returned null");
        return nullptr;
    }
    ArkUI_NumberValue wv; wv.f32 = 240.0f;
    ArkUI_NumberValue hv; hv.f32 = 320.0f;
    ArkUI_AttributeItem wItem; wItem.value = &wv; wItem.size = 1; wItem.string = nullptr; wItem.object = nullptr;
    ArkUI_AttributeItem hItem; hItem.value = &hv; hItem.size = 1; hItem.string = nullptr; hItem.object = nullptr;
    g_node_api->setAttribute(g_xc_node, NODE_WIDTH, &wItem);
    g_node_api->setAttribute(g_xc_node, NODE_HEIGHT, &hItem);
    LOGI("XComponent node created: %{public}p", (void *)g_xc_node);

    // 2) 建 SurfaceHolder（g_xc_node 是 NDK XComponent 节点，Create 应成功）。
    g_holder = OH_ArkUI_SurfaceHolder_Create(g_xc_node);
    if (g_holder == nullptr) {
        LOGE("SurfaceHolder_Create returned null (NDK node=%{public}p)", (void *)g_xc_node);
        // 诊断：确认节点类型（NDK 节点不会崩，可安全调用）。
        int32_t nodeType = OH_ArkUI_NodeUtils_GetNodeType(g_xc_node);
        LOGE("nodeType=%{public}d (XCOMPONENT=12)", nodeType);
    } else {
        // 3) 注册 SurfaceCallback。
        g_surf_cb = OH_ArkUI_SurfaceCallback_Create();
        OH_ArkUI_SurfaceCallback_SetSurfaceCreatedEvent(g_surf_cb, OnSurfCreated);
        OH_ArkUI_SurfaceCallback_SetSurfaceChangedEvent(g_surf_cb, OnSurfChanged);
        OH_ArkUI_SurfaceCallback_SetSurfaceDestroyedEvent(g_surf_cb, OnSurfDestroyed);
        int32_t ar = OH_ArkUI_SurfaceHolder_AddSurfaceCallback(g_holder, g_surf_cb);
        if (ar != ARKUI_ERROR_CODE_NO_ERROR) LOGE("AddSurfaceCallback failed: %{public}d", ar);

        // 4) 注册帧回调（API 20）：在 XComponent 渲染线程驱动 EGL swap。
        int32_t fr = OH_ArkUI_XComponent_RegisterOnFrameCallback(g_xc_node, OnFrameCallback);
        if (fr != ARKUI_ERROR_CODE_NO_ERROR) {
            LOGE("RegisterOnFrameCallback failed: %{public}d", fr);
        } else {
            OH_NativeXComponent_ExpectedRateRange range = {1, 60, 60};
            OH_ArkUI_XComponent_SetExpectedFrameRateRange(g_xc_node, range);
        }
        LOGI("SurfaceHolder ok: holder=%{public}p", (void *)g_holder);
    }

    // 5) 注册 native 触摸事件（替代 ArkTS .onTouch）。
    g_node_api->registerNodeEvent(g_xc_node, NODE_TOUCH_EVENT, 0, nullptr);
    g_node_api->addNodeEventReceiver(g_xc_node, OnNodeTouchEvent);

    // 6) 挂到 NodeContent 上树（按官方 ContentSlot 范式同步挂载）。
    int32_t adr = OH_ArkUI_NodeContent_AddNode(g_content, g_xc_node);
    LOGI("NodeContent_AddNode rc=%{public}d", adr);
    return nullptr;
}

// ---- 模块注册 ----
static napi_value VmrpExport(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"loadLib", nullptr, LoadLib, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"init", nullptr, InitEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setWorkDir", nullptr, SetWorkDir, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMemory", nullptr, SetMemory, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, StartEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, StopEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendKey", nullptr, SendKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMotion", nullptr, SendMotion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMotionSensitivity", nullptr, SetMotionSensitivity, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setShakeIntensity", nullptr, SetShakeIntensity, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setDisplayFilter", nullptr, SetDisplayFilter, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startDsmB", nullptr, StartDsmB, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startDsmC", nullptr, StartDsmC, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startDsmEx", nullptr, StartDsmEx, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"submitEdit", nullptr, SubmitEdit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelEdit", nullptr, CancelEdit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mediaPause", nullptr, MediaPause, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mediaResume", nullptr, MediaResume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEditCallback", nullptr, SetEditCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createSurfaceNode", nullptr, CreateSurfaceNode, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    // OH_ArkUI_SurfaceHolder 方式：不再用 libraryname 自动注入 OH_NATIVE_XCOMPONENT_OBJ，
    // Surface 生命周期由 ArkTS 调 bindNode(frameNode) 主动绑定。
    return exports;
}

// 模块注册入口。
EXTERN_C_START
static napi_value VmrpXComponentInit(napi_env env, napi_value export_obj) {
    return VmrpExport(env, export_obj);
}
EXTERN_C_END

static napi_module vmrp_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = VmrpXComponentInit,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterVmrpModule(void) {
    napi_module_register(&vmrp_module);
}
