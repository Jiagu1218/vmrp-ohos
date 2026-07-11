/*
 * vmrp_audio.cpp - OHAudio 渲染器实现。
 *
 * OHAudio（API 12+）是鸿蒙的低延迟音频 C API。我们创建一个 OUTPUT RENDERER
 * 流，采样率/声道数对齐 vmrp（44100Hz / 2ch / S16LE）。在 WriteData 回调里
 * 调 VmrpEngine::PullAudio() 填充 PCM。
 */
#include "vmrp_audio.h"
#include "vmrp_engine.h"

#include <hilog/log.h>
#include <cstring>

#undef LOG_TAG
#define LOG_TAG "vmrp_audio"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

// C 风格回调，转发到 VmrpAudio 实例。userData 是 VmrpAudio*。
static OH_AudioData_Callback_Result OnWriteDataCb(OH_AudioRenderer *renderer, void *userData,
                                                  void *audioData, int32_t audioDataSize) {
    auto *self = static_cast<VmrpAudio *>(userData);
    if (self) self->OnWriteData(renderer, audioData, audioDataSize);
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void VmrpAudio::OnWriteData(OH_AudioRenderer *renderer, void *audioData, int32_t audioDataSize) {
    (void)renderer;
    auto &eng = VmrpEngine::Instance();
    if (!eng.IsRunning() || eng.IsMediaPaused() || !eng.AudioActive()) {
        memset(audioData, 0, static_cast<size_t>(audioDataSize));
        return;
    }
    int channels = channels_;
    int frame_bytes = channels * static_cast<int>(sizeof(int16_t));
    int frames = audioDataSize / frame_bytes;
    int written = eng.PullAudio(audioData, frames);
    if (written <= 0) {
        memset(audioData, 0, static_cast<size_t>(audioDataSize));
    }
}

int VmrpAudio::Start(int sample_rate, int channels) {
    sample_rate_ = sample_rate;
    channels_ = channels;

    OH_AudioStream_Result r = OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER);
    if (r != AUDIOSTREAM_SUCCESS) { LOGE("builder create failed %d", r); return -1; }

    OH_AudioStreamBuilder_SetSamplingRate(builder_, sample_rate);
    OH_AudioStreamBuilder_SetChannelCount(builder_, channels);
    OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_MUSIC);
    OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_NORMAL);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder_, OnWriteDataCb, this);

    r = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
    if (r != AUDIOSTREAM_SUCCESS) { LOGE("generate renderer failed %d", r); return -1; }

    r = OH_AudioRenderer_Start(renderer_);
    if (r != AUDIOSTREAM_SUCCESS) { LOGE("renderer start failed %d", r); return -1; }

    LOGI("audio started %dHz %dch", sample_rate, channels);
    return 0;
}

void VmrpAudio::Stop() {
    std::lock_guard<std::mutex> lk(mtx_);
    if (renderer_) {
        OH_AudioRenderer_Stop(renderer_);
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
    }
    if (builder_) {
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
    }
}

void VmrpAudio::Pause() {
    std::lock_guard<std::mutex> lk(mtx_);
    if (renderer_) {
        OH_AudioStream_Result r = OH_AudioRenderer_Pause(renderer_);
        LOGI("audio renderer pause: result=%d", r);
    }
}

void VmrpAudio::Resume() {
    std::lock_guard<std::mutex> lk(mtx_);
    if (renderer_) {
        OH_AudioStream_State state = AUDIOSTREAM_STATE_INVALID;
        OH_AudioRenderer_GetCurrentState(renderer_, &state);
        if (state == AUDIOSTREAM_STATE_PAUSED) {
            OH_AudioStream_Result r = OH_AudioRenderer_Start(renderer_);
            LOGI("audio renderer resume: state=%d start=%d", state, r);
        } else {
            LOGI("audio renderer skip resume: state=%d (not paused)", state);
        }
    }
}

VmrpAudio::~VmrpAudio() { Stop(); }
