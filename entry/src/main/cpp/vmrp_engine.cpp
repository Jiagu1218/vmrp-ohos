/*
 * vmrp_engine.cpp - vmrp 引擎桥接核心实现。
 *
 * 通过 dlopen 加载预构建的 libvmrp.so（aarch64-linux-ohos，含 Unicorn arm-softmmu
 * 软件模拟 ARM32），按名称解析 vmrp_api.h 的 18 个导出符号。
 *
 * 线程模型说明（重要）：
 *   - vmrp 内部的 Unicorn ARM 引擎不支持并发访问。所有 Init/SetWorkDir/Start/
 *     Destroy/SendEvent/StepTimer/Screen* 必须在同一线程（引擎线程）调用。
 *   - OHAudio 的渲染回调运行在独立的音频线程。PullAudio() 只读取/拷贝 PCM
 *     缓冲，不调用任何会驱动 Unicorn 的函数，因此可以在音频线程安全调用。
 *     （vmrp 音频状态在无 SDL 时其内部锁为 no-op，且 PCM 数据是预解码好的。）
 */
#include "vmrp_engine.h"

#include <dlfcn.h>
#include <hilog/log.h>
#include <pthread.h>
#include <unistd.h>
#include <sensors/oh_sensor.h>
#include <sensors/vibrator.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <string>
#include <thread>

#undef LOG_TAG
#define LOG_TAG "vmrp_engine"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

// 解析单个符号，失败则记录并返回 false。
#define RESOLVE_SYM(handle, name, field, type)                                  \
    do {                                                                        \
        void *sym = dlsym((handle), (name));                                    \
        if (!(sym)) {                                                           \
            LOGE("dlsym failed for %s: %s", (name), dlerror());                 \
            return false;                                                       \
        }                                                                       \
        api_.field = reinterpret_cast<type>(sym);                               \
    } while (0)

VmrpEngine &VmrpEngine::Instance() {
    static VmrpEngine inst;
    return inst;
}

VmrpEngine::~VmrpEngine() {
    Destroy();
    if (so_handle_ && so_handle_ != RTLD_DEFAULT) {
        dlclose(so_handle_);
    }
    so_handle_ = nullptr;
    loaded_ = false;
}

// 把 vmrp 的 stdout/stderr（printf/fprintf）重定向到 pipe，读取线程转发到 hilog。
// vmrp 核心日志全用 printf/stderr，鸿蒙默认不进 hilog，导致启动失败等关键日志
// 静默丢失。重定向后所有 vmrp 日志都能在 hilog 看到（tag=vmrp_core）。
namespace {
int g_stdout_pipe[2] = {-1, -1};
std::atomic<bool> g_log_thread_run{false};
std::thread g_log_thread;

void StdioLogThread() {
    char buf[1024];
    std::string line;
    while (g_log_thread_run.load()) {
        ssize_t n = read(g_stdout_pipe[0], buf, sizeof(buf) - 1);
        if (n <= 0) {
            if (n == 0) break; // pipe 关闭
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }
        buf[n] = '\0';
        line.append(buf, n);
        size_t pos;
        while ((pos = line.find('\n')) != std::string::npos) {
            std::string one = line.substr(0, pos);
            line.erase(0, pos + 1);
            if (!one.empty()) {
                OH_LOG_INFO(LOG_APP, "vmrp_core: %{public}s", one.c_str());
            }
        }
    }
}

void RedirectStdioToHilog() {
    if (g_log_thread_run.exchange(true)) return; // 已启动
    if (pipe(g_stdout_pipe) != 0) { g_log_thread_run = false; return; }
    // stdout 和 stderr 都指向 pipe 的写端
    dup2(g_stdout_pipe[1], STDOUT_FILENO);
    dup2(g_stdout_pipe[1], STDERR_FILENO);
    // 行缓冲，便于按行读取
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IOLBF, 0);
    g_log_thread = std::thread(StdioLogThread);
}
} // namespace

bool VmrpEngine::Load(const std::string &so_path) {
    if (loaded_) return true;
    // 先重定向 stdout/stderr 到 hilog，确保后续 vmrp 的所有日志可见。
    RedirectStdioToHilog();
    // 鸿蒙 MUSL-LDSO 命名空间隔离禁止 dlopen 绝对路径沙箱 so。
    // 但 libvmrp.so 已作为 libentry.so 的依赖自动加载，dlopen("libvmrp.so")
    // 不会走命名空间检查，而是返回已加载的 handle（引用计数+1）。
    so_handle_ = dlopen("libvmrp.so", RTLD_NOW | RTLD_NOLOAD);
    if (!so_handle_) {
        // RTLD_NOLOAD 失败说明 libvmrp.so 未随 libentry.so 加载，尝试按名加载
        so_handle_ = dlopen("libvmrp.so", RTLD_NOW);
    }
    if (!so_handle_) {
        LOGE("dlopen(libvmrp.so) failed: %s", dlerror());
        return false;
    }
    LOGI("dlopen(libvmrp.so) OK (by name, no namespace check)");

    RESOLVE_SYM(so_handle_, "vmrp_api_init", init, int (*)(int, int));
    RESOLVE_SYM(so_handle_, "vmrp_api_set_work_dir", set_work_dir, int (*)(const char *));
    RESOLVE_SYM(so_handle_, "vmrp_api_start", start, int (*)(const char *, const char *, const char *));
    RESOLVE_SYM(so_handle_, "vmrp_api_destroy", destroy, void (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_is_running", is_running, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_set_dns_map", set_dns_map, int (*)(const char *));

    RESOLVE_SYM(so_handle_, "vmrp_api_event", event, int (*)(int, int, int));
    RESOLVE_SYM(so_handle_, "vmrp_api_motion", motion, int (*)(int, int, int));
    RESOLVE_SYM(so_handle_, "vmrp_api_timer", timer, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_get_timer_interval", get_timer_interval, int (*)(void));

    RESOLVE_SYM(so_handle_, "vmrp_api_get_screen_buffer", get_screen_buffer, const uint16_t *(*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_get_screen_rgba_buffer", get_screen_rgba_buffer, const uint8_t *(*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_get_screen_dirty", get_screen_dirty, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_get_screen_width", get_screen_width, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_get_screen_height", get_screen_height, int (*)(void));

    RESOLVE_SYM(so_handle_, "vmrp_api_audio_sample_rate", audio_sample_rate, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_audio_channels", audio_channels, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_audio_is_active", audio_is_active, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_audio_render_s16le", audio_render_s16le, int (*)(void *, int));
    RESOLVE_SYM(so_handle_, "vmrp_api_audio_stop", audio_stop, void (*)(void));

    RESOLVE_SYM(so_handle_, "vmrp_api_media_pause", media_pause, void (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_media_resume", media_resume, void (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_media_seek", media_seek, int (*)(int));
    RESOLVE_SYM(so_handle_, "vmrp_api_media_position", media_position, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_media_duration", media_duration, int (*)(void));

    RESOLVE_SYM(so_handle_, "vmrp_api_is_edit_active", is_edit_active, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_get_edit_text", get_edit_text, const char *(*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_set_edit_text", set_edit_text, int (*)(const char *));
    RESOLVE_SYM(so_handle_, "vmrp_api_cancel_edit", cancel_edit, int (*)(void));
    // 上游轮询式 motion/shake API（651e421/4fbb0b4）
    RESOLVE_SYM(so_handle_, "vmrp_api_motion_active", motion_active, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_take_shake", take_shake, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_get_screen_rotation", get_screen_rotation, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_set_media_cb", set_media_cb, void (*)(void (*)(void), void (*)(void)));
    RESOLVE_SYM(so_handle_, "vmrp_api_start_dsmB", start_dsmB, int (*)(const char *));
    RESOLVE_SYM(so_handle_, "vmrp_api_start_dsmC", start_dsmC, int (*)(const char *));
    RESOLVE_SYM(so_handle_, "vmrp_api_start_dsm_ex", start_dsm_ex, int (*)(const char *, const char *));

    // Volume API may not exist in older builds; optional resolve.
    {
        void *sym = dlsym(so_handle_, "vmrp_api_set_volume");
        if (sym) api_.set_volume = reinterpret_cast<void (*)(int)>(sym);
        sym = dlsym(so_handle_, "vmrp_api_set_volume_cb");
        if (sym) api_.set_volume_cb = reinterpret_cast<void (*)(void (*)(int))>(sym);
    }

    loaded_ = true;
    LOGI("vmrp API resolved, loaded=true");

    // motion/shake 改为轮询模型（上游 651e421/4fbb0b4）：
    // TimerLoop 每 tick 调 PollMotionShake()，查 motion_active() 启停传感器、
    // take_shake() 驱动 OH_Vibrator。不再注册回调。

    // 注册媒体暂停/恢复回调：dsm.c PAUSE/RESUME 调 vmrp_api_media_pause/resume
    // 时通知宿主停启 OHAudio renderer,避免 renderer 空转拉流。
    if (api_.set_media_cb) {
        api_.set_media_cb(
            []() {
                LOGI("media_pause_cb: active=%d paused=%d running=%d",
                     Instance().AudioActive(), Instance().IsMediaPaused(), Instance().IsRunning());
                VmrpEngine::Instance().SetMediaPaused(true);
                if (VmrpEngine::Instance().audio_pause_fn_)
                    VmrpEngine::Instance().audio_pause_fn_(true);
            },
            []() {
                LOGI("media_resume_cb: active=%d paused=%d running=%d",
                     Instance().AudioActive(), Instance().IsMediaPaused(), Instance().IsRunning());
                VmrpEngine::Instance().SetMediaPaused(false);
                if (VmrpEngine::Instance().audio_pause_fn_)
                    VmrpEngine::Instance().audio_pause_fn_(false);
            }
        );
        LOGI("media pause/resume callback registered");
    }

    // 注册音量回调：dsm.c mr_plat(1302,level) 调 vmrp_api_set_volume 时
    // 通知宿主调 OH_AudioRenderer_SetVolume。
    if (api_.set_volume_cb) {
        api_.set_volume_cb([](int level) {
            VmrpEngine::Instance().SetVolume(level);
        });
        LOGI("volume callback registered");
    }

    return true;
}

bool VmrpEngine::IsRunning() const {
    if (!loaded_) return false;
    return api_.is_running() != 0;
}

int VmrpEngine::Init(int w, int h) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    int ret = api_.init(w, h);
    if (ret == 0 && api_.set_dns_map) {
        api_.set_dns_map(
            "wap.skmeg.com->159.75.119.124;rop.skymobiapp.com->159.75.119.124;"
            "spd.skymobiapp.com->159.75.119.124;freeads.51mrp.com->159.75.119.124;"
            "proxy.51mrp.com->159.75.119.124;proxy2.51mrp.com->159.75.119.124;"
            "help.proxy.51mrp.com->159.75.119.124");
        LOGI("DNS map set: 7 entries (upstream default)");
    }
    return ret;
}
int VmrpEngine::SetWorkDir(const std::string &dir) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    OH_LOG_INFO(LOG_APP, "setWorkDir: %{public}s", dir.c_str());
    return api_.set_work_dir(dir.c_str());
}

int VmrpEngine::Start(const std::string &mrp, const std::string &ext, const std::string &entry) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.start(mrp.c_str(), ext.empty() ? nullptr : ext.c_str(),
                      entry.empty() ? nullptr : entry.c_str());
}

int VmrpEngine::StartDsmB(const std::string &entry) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    if (!api_.start_dsmB) return -1;
    return api_.start_dsmB(entry.empty() ? "*A" : entry.c_str());
}

int VmrpEngine::StartDsmC(const std::string &entry) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    if (!api_.start_dsmC) return -1;
    return api_.start_dsmC(entry.empty() ? "*A" : entry.c_str());
}

int VmrpEngine::StartDsmEx(const std::string &path, const std::string &entry) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    if (!api_.start_dsm_ex) return -1;
    return api_.start_dsm_ex(path.c_str(), entry.empty() ? nullptr : entry.c_str());
}

void VmrpEngine::Destroy() {
    if (!loaded_) return;
    std::lock_guard<std::mutex> lk(engine_mtx_);
    api_.destroy();
}

int VmrpEngine::SendEvent(int code, int p0, int p1) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.event(code, p0, p1);
}

int VmrpEngine::SendMotion(int x, int y, int z) {
    if (!api_.motion) return -1;
    int ret = api_.motion(x, y, z);
    return ret;
}

// 驱动一次 timer() 并返回下一次所需间隔。调用方据此调度下一次 StepTimer。
int VmrpEngine::StepTimer() {
    if (!api_.timer) return 0;
    std::lock_guard<std::mutex> lk(engine_mtx_);
    api_.timer();
    return api_.get_timer_interval ? api_.get_timer_interval() : 0;
}

const uint16_t *VmrpEngine::ScreenBuffer() {
    return api_.get_screen_buffer ? api_.get_screen_buffer() : nullptr;
}
// 走 vmrp 内部 screen_lock 保护的 RGBA 转换路径，async worker 模型下线程安全。
const uint8_t *VmrpEngine::ScreenRgbaBuffer() {
    return api_.get_screen_rgba_buffer ? api_.get_screen_rgba_buffer() : nullptr;
}
int VmrpEngine::ScreenWidth() { return api_.get_screen_width ? api_.get_screen_width() : 0; }
int VmrpEngine::ScreenHeight() { return api_.get_screen_height ? api_.get_screen_height() : 0; }
bool VmrpEngine::ScreenDirty() { return api_.get_screen_dirty && api_.get_screen_dirty() != 0; }

int VmrpEngine::AudioSampleRate() { return api_.audio_sample_rate ? api_.audio_sample_rate() : 44100; }
int VmrpEngine::AudioChannels() { return api_.audio_channels ? api_.audio_channels() : 2; }
bool VmrpEngine::AudioActive() { return api_.audio_is_active && api_.audio_is_active() != 0; }

// OHAudio 回调线程调用：仅拷贝 PCM，不驱动 Unicorn，线程安全。
int VmrpEngine::PullAudio(void *buffer, int frames) {
    if (!api_.audio_render_s16le) return 0;
    return api_.audio_render_s16le(buffer, frames);
}
void VmrpEngine::AudioStop() { if (api_.audio_stop) api_.audio_stop(); }

void VmrpEngine::MediaPause() { media_paused_.store(true, std::memory_order_release); if (api_.media_pause) api_.media_pause(); }
void VmrpEngine::MediaResume() { media_paused_.store(false, std::memory_order_release); if (api_.media_resume) api_.media_resume(); }
int VmrpEngine::MediaSeek(int ms) { return api_.media_seek ? api_.media_seek(ms) : -1; }
int VmrpEngine::MediaPosition() { return api_.media_position ? api_.media_position() : 0; }
int VmrpEngine::MediaDuration() { return api_.media_duration ? api_.media_duration() : 0; }

bool VmrpEngine::EditActive() { return api_.is_edit_active && api_.is_edit_active() != 0; }
std::string VmrpEngine::GetEditText() {
    if (!api_.get_edit_text) return "";
    const char *txt = api_.get_edit_text();
    return txt ? std::string(txt) : std::string();
}
int VmrpEngine::SetEditText(const std::string &text) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.set_edit_text(text.c_str());
}
int VmrpEngine::CancelEdit() {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.cancel_edit();
}

// ---- 加速度传感器（OH_Sensor C 原生 API）----

namespace {
/* 传感器订阅需要的持久对象：Subscribe/Unsubscribe 需传入同一组指针，
 * 故必须是全局或 static，不能栈分配。 */
Sensor_SubscriptionId *g_sensor_sub_id = nullptr;
Sensor_SubscriptionAttribute *g_sensor_sub_attr = nullptr;
Sensor_Subscriber *g_sensor_subscriber = nullptr;

/* OH_Sensor 回调：m/s² → mG 转换 + Y 轴取反 + 灵敏度倍率，
 * 再通过 SendMotion 投递到 vmrp 异步队列。 */
void OnAccelerometerData(Sensor_Event *event) {
    float *data = nullptr;
    uint32_t len = 0;
    if (OH_SensorEvent_GetData(event, &data, &len) != SENSOR_SUCCESS || !data || len < 3) return;
    float s = VmrpEngine::Instance().GetMotionSensitivity();
    // 传感器 Y 轴正方向朝上，MRP 屏幕 Y 轴正方向朝下，需取反。
    // 1 m/s² ≈ 102 mG (1000/9.80665)。
    int xMg = static_cast<int>(data[0] * 102.0f * s);
    int yMg = -static_cast<int>(data[1] * 102.0f * s);
    int zMg = static_cast<int>(data[2] * 102.0f * s);
    VmrpEngine::Instance().SendMotion(xMg, yMg, zMg);
}
} // namespace

void VmrpEngine::StartSensor() {
    if (sensor_subscribed_) return;
    // 创建订阅 ID（SENSOR_TYPE_ACCELEROMETER = 1）
    g_sensor_sub_id = OH_Sensor_CreateSubscriptionId();
    if (!g_sensor_sub_id) { LOGE("OH_Sensor_CreateSubscriptionId failed"); return; }
    OH_SensorSubscriptionId_SetType(g_sensor_sub_id, SENSOR_TYPE_ACCELEROMETER);

    // 设置采样间隔 20ms（20000000ns）
    g_sensor_sub_attr = OH_Sensor_CreateSubscriptionAttribute();
    if (!g_sensor_sub_attr) { LOGE("OH_Sensor_CreateSubscriptionAttribute failed"); return; }
    OH_SensorSubscriptionAttribute_SetSamplingInterval(g_sensor_sub_attr, 20000000);

    // 设置回调
    g_sensor_subscriber = OH_Sensor_CreateSubscriber();
    if (!g_sensor_subscriber) { LOGE("OH_Sensor_CreateSubscriber failed"); return; }
    OH_SensorSubscriber_SetCallback(g_sensor_subscriber, OnAccelerometerData);

    int r = OH_Sensor_Subscribe(g_sensor_sub_id, g_sensor_sub_attr, g_sensor_subscriber);
    if (r == SENSOR_SUCCESS) {
        sensor_subscribed_ = true;
        LOGI("OH_Sensor_Subscribe OK (accelerometer)");
    } else {
        LOGE("OH_Sensor_Subscribe failed: %{public}d", r);
    }
}

void VmrpEngine::StopSensor() {
    if (!sensor_subscribed_) return;
    if (g_sensor_sub_id && g_sensor_subscriber) {
        OH_Sensor_Unsubscribe(g_sensor_sub_id, g_sensor_subscriber);
    }
    if (g_sensor_subscriber) { OH_Sensor_DestroySubscriber(g_sensor_subscriber); g_sensor_subscriber = nullptr; }
    if (g_sensor_sub_attr) { OH_Sensor_DestroySubscriptionAttribute(g_sensor_sub_attr); g_sensor_sub_attr = nullptr; }
    if (g_sensor_sub_id) { OH_Sensor_DestroySubscriptionId(g_sensor_sub_id); g_sensor_sub_id = nullptr; }
    sensor_subscribed_ = false;
    LOGI("OH_Sensor_Unsubscribe OK (accelerometer)");
}

void VmrpEngine::SetMotionSensitivity(float s) {
    // 上游无 set_motion_sensitivity 接口；灵敏度只在宿主侧 OnAccelerometerData
    // 里乘 motion_sensitivity_ 系数，不进入 vmrp。
    motion_sensitivity_ = s;
}

void VmrpEngine::SetShakeIntensity(int level) {
    if (level < 0) level = 0;
    if (level > 2) level = 2;
    shake_intensity_ = level;
    LOGI("shake intensity set to %{public}d (0=light,1=medium,2=strong)", level);
}

// 轮询上游 motion/shake 状态。由 TimerLoop 每 tick 调一次（worker 线程外，
// take_shake/motion_active 只读原子状态，无需 engine_mtx_）。
// - take_shake(): 0=无请求, >0=震动 N 毫秒, -1=停止
// - motion_active(): -1=未监听, >=0=监听中 → 启停 OH_Sensor 订阅
void VmrpEngine::PollMotionShake() {
    if (!loaded_) return;
    // 震动轮询
    if (api_.take_shake) {
        int req = api_.take_shake();
        if (req > 0) {
            int level = shake_intensity_;
            int32_t duration = req > 0 ? req : 200;
            Vibrator_Usage usage = VIBRATOR_USAGE_TOUCH;
            if (level == 0) {
                duration = std::max(50, duration * 3 / 10);
            } else if (level == 2) {
                duration = duration * 2;
                usage = VIBRATOR_USAGE_ALARM;
            }
            Vibrator_Attribute attr;
            attr.vibratorId = 0;
            attr.usage = usage;
            int32_t ret = OH_Vibrator_PlayVibration(duration, attr);
            if (ret != 0) {
                OH_LOG_INFO(LOG_APP, "OH_Vibrator_PlayVibration failed: %{public}d", ret);
            }
        } else if (req == -1) {
            int32_t ret = OH_Vibrator_Cancel();
            if (ret != 0) {
                OH_LOG_INFO(LOG_APP, "OH_Vibrator_Cancel failed: %{public}d", ret);
            }
        }
    }
    // 动感传感器启停轮询：active >=0 时订阅，-1 时取消
    if (api_.motion_active) {
        int active = api_.motion_active();
        if (active >= 0 && !sensor_subscribed_) {
            StartSensor();
        } else if (active < 0 && sensor_subscribed_) {
            StopSensor();
        }
    }
}

void VmrpEngine::SetVolume(int level) {
    if (volume_fn_) volume_fn_(level);
}
