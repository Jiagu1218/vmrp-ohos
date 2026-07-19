/*
 * vmrp_engine.h - vmrp 引擎桥接核心
 *
 * 职责：
 *   1. dlopen 预构建的 libvmrp.so，按函数名解析 skyengine_api.h 的导出符号。
 *   2. 维护单线程串行调度：所有 skyengine_api_* 调用必须在同一线程执行
 *      （Unicorn ARM 引擎不支持并发，参考 vmrp/docs/flutter-integration.md）。
 *   3. 实现 timer 驱动 loop：start/event/timer 后查 get_timer_interval()，
 *      >0 则延时调度下次 timer()，循环往复（vmrp 的 pull 模型）。
 *
 * libvmrp.so 不依赖 SDL（编译时未定义 VMRP_SDL_AUDIO），音频为 pull 模型，
 * 屏幕缓冲为 RGB565（240x320 默认）。
 */
#ifndef VMRP_ENGINE_H
#define VMRP_ENGINE_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>

// skyengine_api.h 的导出函数指针类型（与 skyengine_api.h 中的声明一一对应）。
struct VmrpApi {
    int (*init)(int screen_w, int screen_h);
    int (*set_work_dir)(const char *work_dir);
    int (*start)(const char *mrp_path, const char *ext, const char *entry);
    void (*destroy)(void);
    int (*is_running)(void);
    int (*set_dns_map)(const char *map);

    int (*event)(int code, int p0, int p1);
    int (*motion)(int x_mg, int y_mg, int z_mg);
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

    void (*media_pause)(void);
    void (*media_resume)(void);
    int (*media_seek)(int ms);
    int (*media_position)(void);
    int (*media_duration)(void);

    int (*is_edit_active)(void);
    const char *(*get_edit_text)(void);
    int (*set_edit_text)(const char *text);
    int (*cancel_edit)(void);

    // 上游轮询式 motion/shake API（651e421/4fbb0b4）
    int (*motion_active)(void);     // -1=未监听, 0=晃动, 1=倾斜
    int (*take_shake)(void);        // 0=无请求, >0=震动N毫秒, -1=停止
    int (*get_screen_rotation)(void); // 0=正常,1=90°,2=180°,3=270°

    void (*set_media_cb)(void (*pause_cb)(void), void (*resume_cb)(void));

    void (*set_volume)(int level);
    void (*set_volume_cb)(void (*cb)(int level));

    int (*start_dsmB)(const char *entry);
    int (*start_dsmC)(const char *entry);
    int (*start_dsm_ex)(const char *path, const char *entry);
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
    int StartDsmB(const std::string &entry);
    int StartDsmC(const std::string &entry);
    int StartDsmEx(const std::string &path, const std::string &entry);
    void Destroy();

    // 输入事件（MRP 事件码）。code 见 skyengine_api.h 的 VMRP_* 常量。
    int SendEvent(int code, int p0, int p1);

    // 重力感应数据（mG 单位，静止平放 z≈1000）。
    int SendMotion(int x, int y, int z);

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

    // 媒体播放控制
    void MediaPause();
    void MediaResume();
    int MediaSeek(int ms);
    int MediaPosition();
    int MediaDuration();

    // 音频暂停状态：OnWriteData 回调用此判断是否需要停止填充 PCM。
    bool IsMediaPaused() const { return media_paused_.load(std::memory_order_acquire); }
    void SetMediaPaused(bool paused) { media_paused_.store(paused, std::memory_order_release); }

    using AudioPauseFn = void (*)(bool);
    void SetAudioPauseFn(AudioPauseFn fn) { audio_pause_fn_ = fn; }

    // 音量控制: MRP 调 mr_plat(1302,level) 时回调触发。
    using VolumeFn = void (*)(int level);
    void SetVolumeFn(VolumeFn fn) { volume_fn_ = fn; }
    void SetVolume(int level);

    // 文本编辑。
    bool EditActive();
    std::string GetEditText();
    int SetEditText(const std::string &text);
    int CancelEdit();

    // 加速度传感器：由 TimerLoop 轮询 motion_active() 驱动启停。
    void StartSensor();
    void StopSensor();
    void SetMotionSensitivity(float s);
    float GetMotionSensitivity() const { return motion_sensitivity_; }

    // 震动强度：0=轻, 1=中(默认), 2=强。影响 OH_Vibrator_PlayVibration 的 duration 和 usage。
    void SetShakeIntensity(int level);
    int GetShakeIntensity() const { return shake_intensity_; }

    // 轮询上游 motion/shake 状态。由 TimerLoop 每 tick 调一次：
    // - take_shake() 返回震动请求时驱动 OH_Vibrator
    // - motion_active() 变化时启停加速度传感器
    void PollMotionShake();

    const VmrpApi *Api() const { return &api_; }

private:
    VmrpEngine() = default;
    ~VmrpEngine();
    VmrpEngine(const VmrpEngine &) = delete;
    VmrpEngine &operator=(const VmrpEngine &) = delete;

    void *so_handle_ = nullptr;
    bool loaded_ = false;
    VmrpApi api_ = {};
    bool sensor_subscribed_ = false;
    float motion_sensitivity_ = 1.0f;
    int shake_intensity_ = 1;
    // Unicorn ARM 引擎不支持并发。触摸线程的 SendEvent 和 timer 线程的 StepTimer
    // 都会调 uc_emu_start 执行 ARM 代码，并发会导致 TCG 的 TB cache/链表损坏
    //（translate-all.c g_assert_not_reached，UC_ERR_EXCEPTION），表现为运行中闪退。
    // 用此锁串行化所有驱动 Unicorn 的 skyengine_api 调用。
    std::mutex engine_mtx_;
    std::atomic<bool> media_paused_{false};
    AudioPauseFn audio_pause_fn_ = nullptr;
    VolumeFn volume_fn_ = nullptr;
};

#endif // VMRP_ENGINE_H
