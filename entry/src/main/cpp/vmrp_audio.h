/*
 * vmrp_audio.h - OHAudio 渲染器（拉流式）
 *
 * skyengine 的音频是 pull 模型：skyengine_api_audio_render_s16le(buf, frames) 把
 * 已解码/合成的 S16LE 立体声 PCM 写入调用方缓冲。OHAudio 的渲染回调正好
 * 是 pull 语义（它要求我们填充音频数据），二者匹配。
 *
 * 线程安全：WriteData 回调运行在 OHAudio 的内部线程，只调用
 * VmrpEngine::PullAudio()（纯 PCM 拷贝，不驱动 Unicorn），线程安全。
 */
#ifndef VMRP_AUDIO_H
#define VMRP_AUDIO_H

#include <mutex>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>

class VmrpAudio {
public:
    VmrpAudio() = default;
    ~VmrpAudio();

    // 启动渲染流。sample_rate / channels 来自 vmrp（44100 / 2）。
    int Start(int sample_rate, int channels);
    void Stop();

    // PAUSE: 暂停 OHAudio renderer(停止拉流回调),RESUME: 恢复。
    // 配合 skyengine_api_media_pause/resume，暂停时 renderer 不再消耗 CPU。
    void Pause();
    void Resume();

    // 音量控制: level 0~10 映射到 OH_AudioRenderer_SetVolume [0.0,1.0]。
    void SetVolume(int level);

    // OHAudio callback (audio thread): fill PCM data.
    void OnWriteData(OH_AudioRenderer *renderer, void *audioData, int32_t audioDataSize);

private:
    OH_AudioStreamBuilder *builder_  = nullptr;
    OH_AudioRenderer      *renderer_ = nullptr;
    int sample_rate_ = 44100;
    int channels_    = 2;
    std::mutex mtx_;
};

#endif // VMRP_AUDIO_H
