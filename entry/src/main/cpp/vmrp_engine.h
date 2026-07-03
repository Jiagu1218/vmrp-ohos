/*
 * vmrp_engine.h - vmrp 引擎桥接核心
 *
 * 职责：
 *   1. dlopen 预构建的 libvmrp.so，按函数名解析 vmrp_api.h 的 18 个导出符号。
 *   2. 维护单线程串行调度：所有 vmrp_api_* 调用必须在同一线程执行
 *      （Unicorn ARM 引擎不支持并发，参考 vmrp/docs/flutter-integration.md）。
 *   3. 实现 timer 驱动 loop：start/event/timer 后查 get_timer_interval()，
 *      >0 则延时调度下次 timer()，循环往复（vmrp 的 pull 模型）。
 *
 * libvmrp.so 不依赖 SDL（编译时未定义 VMRP_SDL_AUDIO），音频为 pull 模型，
 * 屏幕缓冲为 RGB565（240x320 默认）。
 */
#ifndef VMRP_ENGINE_H
#define VMRP_ENGINE_H

#include <cstdint>
#include <mutex>
#include <string>

// vmrp_api.h 的导出函数指针类型（与 vmrp_api.h 中的声明一一对应）。
struct VmrpApi {
    int (*init)(int screen_w, int screen_h);
    int (*set_work_dir)(const char *work_dir);
    int (*start)(const char *mrp_path, const char *ext, const char *entry);
    void (*destroy)(void);
    int (*is_running)(void);
    int (*set_dns_map)(const char *map);

    int (*event)(int code, int p0, int p1);
    int (*timer)(void);
    int (*get_timer_interval)(void);

    const uint16_t *(*get_screen_buffer)(void);
    const uint8_t *(*get_screen_rgba_buffer)(void);
    int (*get_screen_dirty)(void);
    int (*get_screen_width)(void);
    int (*get_screen_height)(void);

    int (*audio_sample_rate)(void);
    int (*audio_channels)(void);
    int (*audio_is_active)(void);
    int (*audio_render_s16le)(void *buffer, int frames);
    void (*audio_stop)(void);

    int (*is_edit_active)(void);
    const char *(*get_edit_text)(void);
    int (*set_edit_text)(const char *text);
    int (*cancel_edit)(void);
};

// 单例引擎。所有方法都应在引擎线程（EngineThread）上调用；
// 外部线程（如 OHAudio 回调线程）只允许调用 PullAudio()，它内部不触碰 Unicorn。
class VmrpEngine {
public:
    static VmrpEngine &Instance();

    // 加载 libvmrp.so 并解析符号。成功返回 true。
    bool Load(const std::string &so_path);

    // 是否已加载且模拟器在运行。
    bool IsLoaded() const { return loaded_; }
    bool IsRunning() const;

    // 生命周期（必须在引擎线程调用）。
    int Init(int w, int h);
    int SetWorkDir(const std::string &dir);
    int Start(const std::string &mrp, const std::string &ext, const std::string &entry);
    void Destroy();

    // 输入事件（MRP 事件码）。code 见 vmrp_api.h 的 VMRP_* 常量。
    int SendEvent(int code, int p0, int p1);

    // 定时器：驱动一次 timer()，返回下一次需要的间隔（ms），0 表示无需再调度。
    int StepTimer();

    // 屏幕访问（RGB565）。dirty 会在读取后自动清除。
    const uint16_t *ScreenBuffer();
    // 屏幕访问（RGBA8888，vmrp 内部 screen_lock 保护，async 下线程安全）。
    const uint8_t *ScreenRgbaBuffer();
    int ScreenWidth();
    int ScreenHeight();
    bool ScreenDirty();

    // 音频：在 OHAudio 回调线程上调用，仅做 PCM 拷贝，不触碰 Unicorn 引擎。
    int AudioSampleRate();
    int AudioChannels();
    bool AudioActive();
    int PullAudio(void *buffer, int frames); // 返回写入的帧数
    void AudioStop();

    // 文本编辑。
    bool EditActive();
    // 获取当前待编辑的原文本（编辑激活时为 MRP 传入的初始文本，否则空串）。
    // 返回的指针在下次调用前有效（vmrp 内部维护快照），调用方应立即拷贝。
    std::string GetEditText();
    int SetEditText(const std::string &text);
    int CancelEdit();

    const VmrpApi *Api() const { return &api_; }

private:
    VmrpEngine() = default;
    ~VmrpEngine();
    VmrpEngine(const VmrpEngine &) = delete;
    VmrpEngine &operator=(const VmrpEngine &) = delete;

    void *so_handle_ = nullptr;
    bool loaded_ = false;
    VmrpApi api_ = {};
    // Unicorn ARM 引擎不支持并发。触摸线程的 SendEvent 和 timer 线程的 StepTimer
    // 都会调 uc_emu_start 执行 ARM 代码，并发会导致 TCG 的 TB cache/链表损坏
    //（translate-all.c g_assert_not_reached，UC_ERR_EXCEPTION），表现为运行中闪退。
    // 用此锁串行化所有驱动 Unicorn 的 vmrp_api 调用。
    std::mutex engine_mtx_;
};

#endif // VMRP_ENGINE_H
