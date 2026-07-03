/*
 * vmrp_napi.cpp - NAPI 桥接主入口。
 *
 * 把 VmrpEngine/VmrpRenderer/VmrpAudio 整合为 ArkTS 可调用的 NAPI 模块，
 * 并注册为 XComponent 的 native 插件（OH_NativeXComponent 方式，接收 surface
 * 生命周期 + 触摸事件）。
 *
 * partial render 修复（路径B）：旧实现 OnSurfaceCreated 一次性取尺寸（可能拿到
 * 布局中间态 384x384），OnSurfaceChanged 是空壳。本实现：
 *   - OnSurfaceCreated 用占位尺寸建 EGL surface（不依赖最终尺寸）；
 *   - OnSurfaceChanged 拿到 window 后用 OH_NativeXComponent_GetXComponentSize 取最终
 *     物理像素尺寸，调 renderer.RebuildSurface 重设 SET_BUFFER_GEOMETRY + 重建 eglSurface，
 *     彻底纠正 Created 时拿到的中间态尺寸。
 *
 * 线程：所有 vmrp 引擎调用（Init/Start/Event/Timer/Render）都在 XComponent 的工作线程
 * 或定时器线程上执行，保证 Unicorn 引擎单线程串行。EGL 渲染在 XComponent 渲染线程
 * （帧回调线程），避免 EGL surface 跨线程 swap。
 */
#include "napi/native_api.h"
#include "vmrp_engine.h"
#include "vmrp_renderer.h"
#include "vmrp_audio.h"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>

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

// 触摸事件码（vmrp_api.h）。
constexpr int VMRP_MOUSE_DOWN = 2;
constexpr int VMRP_MOUSE_UP   = 3;
constexpr int VMRP_MOUSE_MOVE = 12;
} // namespace

// 这几个函数在全局命名空间定义（无 namespace），供本文件各处调用。
void TryRender();
void TryRenderForce(); // 不管 dirty 都渲染一帧（确保持续上屏）
void NotifyEditIfNeeded();
void RequestRender();

// XComponent 句柄：用于在 OnSurfaceCreated 时注册帧回调。
// 渲染必须在 XComponent 的渲染线程（帧回调线程）执行，否则 EGL surface 跨
// 线程 swap 会报 EGL_BAD_SURFACE（window surface 与创建它的 XComponent 绑定）。
OH_NativeXComponent *g_xcomp = nullptr;
// 渲染请求标志：timer 线程驱动引擎后置位，帧回调线程消费并渲染。
std::atomic<bool> g_need_render{false};

// 帧回调：在 XComponent 渲染线程（与 OnSurfaceCreated 同线程）执行。
// 这是渲染 EGL surface 的正确线程。timer 线程只置 g_need_render，不直接渲染。
static void OnFrameCallback(OH_NativeXComponent *component, uint64_t timestamp, uint64_t targetTimestamp) {
    (void)component; (void)timestamp; (void)targetTimestamp;
    // 引擎运行时每帧都渲染并 swap：XComponent 的 EGL window surface 是双缓冲，
    // 需要持续 eglSwapBuffers 才能维持画面显示。dsm_gm 等静态画面画完一帧后不再
    // dirty，但 window surface 必须持续 swap 否则内容会被回收导致黑屏。
    if (g_engine_running.load()) {
        TryRenderForce();
    } else if (g_need_render.exchange(false)) {
        TryRender();
    }
}

// ---- XComponent 回调 ----
static void OnSurfaceCreated(OH_NativeXComponent *component, void *window) {
    g_xcomp = component;
    // Created 时用引擎逻辑尺寸(240x320)建 EGL surface（占位，最终尺寸由 Changed 兜底）。
    int32_t w = VmrpEngine::Instance().ScreenWidth();
    int32_t h = VmrpEngine::Instance().ScreenHeight();
    if (w <= 0) w = 240;
    if (h <= 0) h = 320;
    std::lock_guard<std::mutex> lk(g_render_mtx);
    g_renderer.OnSurfaceCreated(window);
    // 注册帧回调：在 XComponent 渲染线程做渲染，避免 EGL surface 跨线程。
    OH_NativeXComponent_RegisterOnFrameCallback(component, OnFrameCallback);
    OH_NativeXComponent_ExpectedRateRange range = {1, 60, 60};
    OH_NativeXComponent_SetExpectedFrameRateRange(component, &range);
    LOGI("OnSurfaceCreated screen=%dx%d, frame callback registered", w, h);
}

static void OnSurfaceChanged(OH_NativeXComponent *component, void *window) {
    // 路径B 核心修复：用 XComponent 物理像素尺寸兜底重建 surface。
    // Created 时 surface 尺寸可能是布局中间态（如 384x384），Changed 时取最终尺寸
    // 重设 SET_BUFFER_GEOMETRY + 重建 eglSurface，纠正渲染区域。
    uint64_t surf_w = 0, surf_h = 0;
    int32_t gret = OH_NativeXComponent_GetXComponentSize(component, window, &surf_w, &surf_h);
    std::lock_guard<std::mutex> lk(g_render_mtx);
    if (gret == 0 && surf_w > 0 && surf_h > 0) {
        g_renderer.RebuildSurface((int32_t)surf_w, (int32_t)surf_h);
        LOGI("OnSurfaceChanged rebuilt to %llux%llu",
             (unsigned long long)surf_w, (unsigned long long)surf_h);
    }
}

static void OnSurfaceDestroyed(OH_NativeXComponent *component, void *window) {
    (void)window;
    if (component) {
        OH_NativeXComponent_UnregisterOnFrameCallback(component);
    }
    std::lock_guard<std::mutex> lk(g_render_mtx);
    g_renderer.OnSurfaceDestroyed();
    g_xcomp = nullptr;
}

// 把 XComponent 触摸事件转成 vmrp 的鼠标事件。
static void DispatchTouchEvent(OH_NativeXComponent *component, void *window) {
    (void)window;
    OH_NativeXComponent_TouchEvent touch;
    int32_t r = OH_NativeXComponent_GetTouchEvent(component, window, &touch);
    if (r != 0) return;

    int32_t sw = VmrpEngine::Instance().ScreenWidth();
    int32_t sh = VmrpEngine::Instance().ScreenHeight();
    if (sw <= 0) sw = 240;
    if (sh <= 0) sh = 320;

    uint64_t xcomp_w = 0, xcomp_h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &xcomp_w, &xcomp_h);

    float x = touch.x;
    float y = touch.y;
    if (touch.numPoints > 0) {
        x = touch.touchPoints[0].x;
        y = touch.touchPoints[0].y;
    }

    // 归一化到 [0,1] 再映射到 MRP 屏幕坐标。
    int32_t mx, my;
    if (xcomp_w > 0 && xcomp_h > 0) {
        mx = static_cast<int32_t>(x / xcomp_w * sw);
        my = static_cast<int32_t>(y / xcomp_h * sh);
    } else {
        mx = static_cast<int32_t>(x);
        my = static_cast<int32_t>(y);
    }
    if (mx < 0) mx = 0; if (mx >= sw) mx = sw - 1;
    if (my < 0) my = 0; if (my >= sh) my = sh - 1;

    int code = -1;
    if (touch.type == OH_NativeXComponent_TouchEventType::OH_NATIVEXCOMPONENT_DOWN) {
        code = VMRP_MOUSE_DOWN;
    } else if (touch.type == OH_NativeXComponent_TouchEventType::OH_NATIVEXCOMPONENT_UP) {
        code = VMRP_MOUSE_UP;
    } else if (touch.type == OH_NativeXComponent_TouchEventType::OH_NATIVEXCOMPONENT_MOVE) {
        code = VMRP_MOUSE_MOVE;
    }
    if (code >= 0) {
        VmrpEngine::Instance().SendEvent(code, mx, my);
        RequestRender();
    }
}

static OH_NativeXComponent_Callback g_xcomp_cb = {
    OnSurfaceCreated, OnSurfaceChanged, OnSurfaceDestroyed, DispatchTouchEvent
};

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
// vmrp_api.c 在 VMRP_API_ASYNC_RUNNER=1 下采用 async worker 模型：vmrp_api_start
// 成功后自动起 worker 线程自驱 timer()/event()。本循环不再调 StepTimer()，
// 只做两件事：1) 周期请求渲染；2) 检测引擎退出。
static void TimerLoop() {
    LOGI("timer loop started (async: render-only)");
    while (g_timer_running.load()) {
        if (!g_engine_running.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }
        RequestRender();
        NotifyEditIfNeeded();
        if (!VmrpEngine::Instance().IsRunning()) {
            g_engine_running.store(false);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
    }
    LOGI("timer loop exited");
}

// 编辑通知：状态从无到有时回调 ArkTS。
static std::atomic<bool> g_edit_notified{false};
void NotifyEditIfNeeded() {
    bool active = VmrpEngine::Instance().EditActive();
    if (active && !g_edit_notified.exchange(true)) {
        if (g_edit_tsfn) {
            napi_acquire_threadsafe_function(g_edit_tsfn);
            napi_call_threadsafe_function(g_edit_tsfn, nullptr, napi_tsfn_nonblocking);
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

// ---- 编辑回调 threadsafe function ----
static void CallJsEdit(napi_env env, napi_value js_cb, void * /*context*/, void * /*data*/) {
    if (env && js_cb) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_cb, 0, nullptr, nullptr);
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

// ---- 模块注册 ----
static napi_value VmrpExport(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"loadLib", nullptr, LoadLib, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"init", nullptr, InitEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setWorkDir", nullptr, SetWorkDir, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, StartEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, StopEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendKey", nullptr, SendKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"submitEdit", nullptr, SubmitEdit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelEdit", nullptr, CancelEdit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEditCallback", nullptr, SetEditCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    // 注册为 XComponent 的 native 插件（OH_NativeXComponent 方式）。
    napi_value export_instance = nullptr;
    napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &export_instance);
    OH_NativeXComponent *native_xcomp = nullptr;
    napi_unwrap(env, export_instance, reinterpret_cast<void **>(&native_xcomp));
    if (native_xcomp) {
        OH_NativeXComponent_RegisterCallback(native_xcomp, &g_xcomp_cb);
        LOGI("XComponent callback registered");
    } else {
        LOGE("XComponent native object not found");
    }
    return exports;
}

// XComponent 通过该符号发现并传入 native 组件对象。
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
