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
    if (so_handle_) {
        dlclose(so_handle_);
        so_handle_ = nullptr;
    }
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
    // RTLD_NOW：立即解析所有符号，便于在加载时发现问题（如 ABI 不匹配）。
    // RTLD_LOCAL：符号不泄露到全局，避免与其它库冲突。
    so_handle_ = dlopen(so_path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!so_handle_) {
        LOGE("dlopen(%s) failed: %s", so_path.c_str(), dlerror());
        return false;
    }
    LOGI("dlopen(%s) OK", so_path.c_str());

    RESOLVE_SYM(so_handle_, "vmrp_api_init", init, int (*)(int, int));
    RESOLVE_SYM(so_handle_, "vmrp_api_set_work_dir", set_work_dir, int (*)(const char *));
    RESOLVE_SYM(so_handle_, "vmrp_api_start", start, int (*)(const char *, const char *, const char *));
    RESOLVE_SYM(so_handle_, "vmrp_api_destroy", destroy, void (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_is_running", is_running, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_set_dns_map", set_dns_map, int (*)(const char *));

    RESOLVE_SYM(so_handle_, "vmrp_api_event", event, int (*)(int, int, int));
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

    RESOLVE_SYM(so_handle_, "vmrp_api_is_edit_active", is_edit_active, int (*)(void));
    RESOLVE_SYM(so_handle_, "vmrp_api_set_edit_text", set_edit_text, int (*)(const char *));
    RESOLVE_SYM(so_handle_, "vmrp_api_cancel_edit", cancel_edit, int (*)(void));

    loaded_ = true;
    LOGI("vmrp API resolved, loaded=true");
    return true;
}

bool VmrpEngine::IsRunning() const {
    if (!loaded_) return false;
    return api_.is_running() != 0;
}

int VmrpEngine::Init(int w, int h) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.init(w, h);
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

void VmrpEngine::Destroy() {
    if (!loaded_) return;
    std::lock_guard<std::mutex> lk(engine_mtx_);
    api_.destroy();
}

int VmrpEngine::SendEvent(int code, int p0, int p1) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.event(code, p0, p1);
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

bool VmrpEngine::EditActive() { return api_.is_edit_active && api_.is_edit_active() != 0; }
int VmrpEngine::SetEditText(const std::string &text) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.set_edit_text(text.c_str());
}
int VmrpEngine::CancelEdit() {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.cancel_edit();
}
