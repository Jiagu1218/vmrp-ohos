/* ohos_midi_tsf.c - TinySoundFont MIDI 合成桥接层。
 *
 * 替换上游 native_dsm_funcs.c 中的简易合成器 (方波/噪音)，
 * 使用 SoundFont2 采样音色合成 MIDI BGM，大幅提升音质。
 *
 * 架构:
 *   上游 native_audio_play_midi() 调本模块的 tsf_midi_play()
 *   → tml_load_memory() 解析 SMF → tml_message 链表
 *   → OHAudio 回调调 tsf_midi_render() → 按 ms 时间戳推进 MIDI 事件
 *   → tsf_channel_note_on/off + tsf_render_short() → S16LE PCM
 *
 * SF2 音色库由宿主 (vmrp_engine.cpp) 从 rawfile 加载后通过
 * tsf_midi_load_soundfont() 注入; 如未加载则降级回上游合成器。
 *
 * 许可证: MIT (与 TinySoundFont 一致)
 */

#ifdef OHOS_TSF_MIDI

#include "ohos_midi_tsf.h"
#include "tsf.h"
#include "tml.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 与 native_dsm_funcs.c 中的 AUDIO_SAMPLE_RATE / AUDIO_CHANNELS 一致 */
#define TSF_MIDI_SAMPLE_RATE 44100
#define TSF_MIDI_CHANNELS    2

/* ---------- 全局 TSF 状态 ---------- */

/* SF2 合成器实例, 由 tsf_midi_load_soundfont() 创建 */
static tsf *g_tsf = NULL;

/* 当前播放的 MIDI 消息链表头 */
static tml_message *g_midi_msg = NULL;

/* 下一条待处理的 MIDI 消息 */
static tml_message *g_midi_next = NULL;

/* 当前播放时间 (ms) */
static double g_midi_msec = 0.0;

/* MIDI 总时长 (ms), 由 tml_get_info 获取 */
static unsigned int g_midi_total_ms = 0;

/* 是否循环播放 */
static int g_midi_loop = 0;

/* ---------- SF2 加载 ---------- */

/* 从内存加载 SF2 音色库。成功返回 1, 失败返回 0。
 * 调用方负责管理 buffer 生命周期 (g_tsf 内部拷贝了数据, buffer 可立即释放)。
 * 初始设置: 44100Hz, 立体声交织, 增益 0dB, 最大 48 复音。 */
int tsf_midi_load_soundfont(const void *sf2_data, int sf2_size) {
    if (g_tsf) { tsf_close(g_tsf); g_tsf = NULL; }
    g_tsf = tsf_load_memory(sf2_data, sf2_size);
    if (!g_tsf) {
        printf("ohos_midi_tsf: tsf_load_memory failed (size=%d)\n", sf2_size);
        return 0;
    }
    tsf_set_output(g_tsf, TSF_STEREO_INTERLEAVED, TSF_MIDI_SAMPLE_RATE, 0.0f);
    tsf_set_max_voices(g_tsf, 48);

    /* 初始化所有 16 通道: 普通通道 bank=0, drum 通道(ch9) bank=128 */
    for (int ch = 0; ch < 16; ch++) {
        tsf_channel_set_bank_preset(g_tsf, ch, (ch == 9) ? 128 : 0, 0);
    }

    printf("ohos_midi_tsf: SF2 loaded OK (size=%d, presets=%d)\n",
           sf2_size, tsf_get_presetcount(g_tsf));
    return 1;
}

/* 释放 SF2 资源 */
void tsf_midi_unload_soundfont(void) {
    if (g_tsf) { tsf_close(g_tsf); g_tsf = NULL; }
}

/* 从文件加载 SF2 音色库。成功返回 1, 失败返回 0。
 * 内部 fopen/fread 读文件到内存后调 tsf_load_memory。
 * OHOS 环境下文件系统只读沙箱目录可访问。 */
int tsf_midi_load_soundfont_file(const char *path) {
    if (!path) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) {
        printf("ohos_midi_tsf: cannot open SF2 '%s'\n", path);
        return 0;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) {
        printf("ohos_midi_tsf: SF2 file empty or seek failed '%s'\n", path);
        fclose(f);
        return 0;
    }
    void *buf = malloc((size_t)sz);
    if (!buf) {
        printf("ohos_midi_tsf: malloc(%ld) failed for SF2\n", sz);
        fclose(f);
        return 0;
    }
    if ((long)fread(buf, 1, (size_t)sz, f) != sz) {
        printf("ohos_midi_tsf: fread failed for SF2 '%s'\n", path);
        free(buf);
        fclose(f);
        return 0;
    }
    fclose(f);

    int ret = tsf_midi_load_soundfont(buf, (int)sz);
    free(buf);  /* tsf_load_memory 内部已拷贝数据, buf 可释放 */
    if (ret) {
        printf("ohos_midi_tsf: SF2 loaded from file '%s' (%ld bytes)\n", path, sz);
    }
    return ret;
}

/* 自动搜索并加载 SF2 音色库。
 * 在 work_dir 下的 soundfont/ 子目录中搜索 .sf2 文件。
 * OHOS 沙箱结构: work_dir = <sandbox>/files, SF2 在 <sandbox>/files/soundfont/
 * 已加载过则跳过(幂等)。
 * 找到第一个可加载的 SF2 即返回 1, 全部失败返回 0。 */
int tsf_midi_auto_load_soundfont(const char *work_dir) {
    if (!work_dir || !*work_dir) return 0;
    if (g_tsf) return 1;  /* 幂等: 已加载 */

    /* 先尝试读取 .active_sf2 文件，获取用户选择的 SF2 文件名 */
    {
        char active_path[1536];
        snprintf(active_path, sizeof(active_path), "%s/soundfont/.active_sf2", work_dir);
        FILE *af = fopen(active_path, "r");
        if (af) {
            char active_name[256] = {0};
            if (fgets(active_name, sizeof(active_name), af)) {
                /* 去除尾部换行/空白 */
                size_t len = strlen(active_name);
                while (len > 0 && (active_name[len-1] == '\n' || active_name[len-1] == '\r' || active_name[len-1] == ' '))
                    active_name[--len] = '\0';
                if (active_name[0] != '\0') {
                    char sf2_path[1536];
                    snprintf(sf2_path, sizeof(sf2_path), "%s/soundfont/%s", work_dir, active_name);
                    if (tsf_midi_load_soundfont_file(sf2_path)) {
                        fclose(af);
                        return 1;
                    }
                    printf("ohos_midi_tsf: .active_sf2 '%s' load failed, falling back to search list\n", active_name);
                }
            }
            fclose(af);
        }
    }

    /* 构造搜索路径: work_dir/soundfont/ (优先 TimGM6mb: GM 全覆盖 128 音色+打击乐) */
    static const char *sf2_names[] = {
        "soundfont/TimGM6mb.sf2",
        "soundfont/florestan-subset.sf2",
        "soundfont/default.sf2",
        NULL
    };

    for (int i = 0; sf2_names[i] != NULL; i++) {
        char path[1536];
        snprintf(path, sizeof(path), "%s/%s", work_dir, sf2_names[i]);
        if (tsf_midi_load_soundfont_file(path)) {
            return 1;
        }
    }

    printf("ohos_midi_tsf: no SF2 found in %s/soundfont/, MIDI will use fallback synth\n",
           work_dir);
    return 0;
}

/* 按名称加载 SF2 音色库。
 * 在 work_dir/soundfont/<name> 路径下加载指定 SF2 文件。
 * 成功返回 1, 失败返回 0。幂等(已加载则跳过)。 */
int tsf_midi_load_soundfont_by_name(const char *work_dir, const char *name) {
    if (!work_dir || !*work_dir || !name || !*name) return 0;
    if (g_tsf) return 1;  /* 幂等: 已加载 */

    char path[1536];
    snprintf(path, sizeof(path), "%s/soundfont/%s", work_dir, name);
    return tsf_midi_load_soundfont_file(path);
}

/* ---------- MIDI 播放控制 ---------- */

/* 开始播放 SMF MIDI 数据。loop!=0 时循环。
 * 成功返回 0 (MR_SUCCESS), 失败返回 -1 (MR_FAILED)。
 * 如 g_tsf 未加载 (SF2 缺失), 返回 -2 通知调用方降级到上游合成器。 */
int tsf_midi_play(const void *midi_data, int midi_size, int loop) {
    if (!g_tsf) {
        printf("ohos_midi_tsf: no SF2 loaded, caller should fallback\n");
        return -2;
    }

    /* 释放上一首 */
    if (g_midi_msg) { tml_free(g_midi_msg); g_midi_msg = NULL; }

    g_midi_msg = tml_load_memory(midi_data, midi_size);
    if (!g_midi_msg) {
        printf("ohos_midi_tsf: tml_load_memory failed (size=%d)\n", midi_size);
        return -1;
    }

    /* 获取总时长 */
    tml_get_info(g_midi_msg, NULL, NULL, NULL, NULL, &g_midi_total_ms);

    g_midi_next = g_midi_msg;
    g_midi_msec = 0.0;
    g_midi_loop = loop ? 1 : 0;

    /* 重置合成器通道状态 */
    tsf_reset(g_tsf);
    for (int ch = 0; ch < 16; ch++) {
        tsf_channel_set_bank_preset(g_tsf, ch, (ch == 9) ? 128 : 0, 0);
    }

    printf("ohos_midi_tsf: playing MIDI (size=%d, duration=%u ms, loop=%d)\n",
           midi_size, g_midi_total_ms, g_midi_loop);
    return 0;
}

/* 停止播放 */
void tsf_midi_stop(void) {
    if (g_midi_msg) { tml_free(g_midi_msg); g_midi_msg = NULL; }
    g_midi_next = NULL;
    g_midi_msec = 0.0;
    g_midi_total_ms = 0;
    if (g_tsf) tsf_note_off_all(g_tsf);
}

/* 暂停/恢复: 暂停时 render 仍被调用但跳过事件推进 */
static int g_midi_paused = 0;
void tsf_midi_pause(void)  { g_midi_paused = 1; }
void tsf_midi_resume(void) { g_midi_paused = 0; }

/* 获取当前播放位置 (ms) */
int tsf_midi_position(void) {
    return (int)g_midi_msec;
}

/* 获取总时长 (ms) */
int tsf_midi_duration(void) {
    return (int)g_midi_total_ms;
}

/* Seek: 重置到 ms 位置。简化实现: 从头重放到目标时间 */
int tsf_midi_seek(int ms) {
    if (!g_midi_msg || !g_tsf) return -1;

    /* 重置到起点 */
    g_midi_next = g_midi_msg;
    g_midi_msec = 0.0;
    tsf_reset(g_tsf);
    for (int ch = 0; ch < 16; ch++) {
        tsf_channel_set_bank_preset(g_tsf, ch, (ch == 9) ? 128 : 0, 0);
    }

    /* 快进到目标时间: 处理所有 ms 之前的事件, 不渲染音频 */
    double target = (double)ms;
    while (g_midi_next && g_midi_next->time <= (unsigned int)target) {
        switch (g_midi_next->type) {
            case TML_PROGRAM_CHANGE:
                tsf_channel_set_presetnumber(g_tsf, g_midi_next->channel,
                                             g_midi_next->program,
                                             (g_midi_next->channel == 9));
                break;
            case TML_NOTE_ON:
                tsf_channel_note_on(g_tsf, g_midi_next->channel,
                                    g_midi_next->key,
                                    g_midi_next->velocity / 127.0f);
                break;
            case TML_NOTE_OFF:
                tsf_channel_note_off(g_tsf, g_midi_next->channel,
                                     g_midi_next->key);
                break;
            case TML_PITCH_BEND:
                tsf_channel_set_pitchwheel(g_tsf, g_midi_next->channel,
                                           g_midi_next->pitch_bend);
                break;
            case TML_CONTROL_CHANGE:
                tsf_channel_midi_control(g_tsf, g_midi_next->channel,
                                         g_midi_next->control,
                                         g_midi_next->control_value);
                break;
        }
        g_midi_next = g_midi_next->next;
    }
    g_midi_msec = target;

    /* 静音当前发声的音符 (seek 后可能有不和谐残音) */
    tsf_note_off_all(g_tsf);
    return 0;
}

/* ---------- 音频渲染 ---------- */

/* 渲染 frames 帧音频到 buffer (S16LE 立体声交织)。
 * 在 OHAudio WriteData 回调中调用。
 * 返回实际渲染的帧数 (frames 或 0 表示静音)。 */
int tsf_midi_render(short *buffer, int frames) {
    if (!g_tsf || !g_midi_msg) {
        memset(buffer, 0, (size_t)(frames * TSF_MIDI_CHANNELS * sizeof(short)));
        return 0;
    }

    if (g_midi_paused) {
        /* 暂停时不推进时间, 但继续渲染衰减 (release 尾音) */
        tsf_render_short(g_tsf, buffer, frames, 0);
        return frames;
    }

    /* 每次渲染 TSF_RENDER_EFFECTSAMPLEBLOCK (64) 帧,
     * 逐块推进 MIDI 时间并触发事件, 与 example3.c 一致 */
    int remaining = frames;
    short *out = buffer;
    while (remaining > 0) {
        int block = (remaining > 64) ? 64 : remaining;

        /* 推进时间并处理 MIDI 事件 */
        g_midi_msec += block * (1000.0 / TSF_MIDI_SAMPLE_RATE);
        while (g_midi_next && g_midi_msec >= g_midi_next->time) {
            switch (g_midi_next->type) {
                case TML_PROGRAM_CHANGE:
                    tsf_channel_set_presetnumber(g_tsf, g_midi_next->channel,
                                                 g_midi_next->program,
                                                 (g_midi_next->channel == 9));
                    break;
                case TML_NOTE_ON:
                    tsf_channel_note_on(g_tsf, g_midi_next->channel,
                                        g_midi_next->key,
                                        g_midi_next->velocity / 127.0f);
                    break;
                case TML_NOTE_OFF:
                    tsf_channel_note_off(g_tsf, g_midi_next->channel,
                                         g_midi_next->key);
                    break;
                case TML_PITCH_BEND:
                    tsf_channel_set_pitchwheel(g_tsf, g_midi_next->channel,
                                               g_midi_next->pitch_bend);
                    break;
                case TML_CONTROL_CHANGE:
                    tsf_channel_midi_control(g_tsf, g_midi_next->channel,
                                             g_midi_next->control,
                                             g_midi_next->control_value);
                    break;
            }
            g_midi_next = g_midi_next->next;
        }

        /* 渲染一个 block */
        tsf_render_short(g_tsf, out, block, 0);

        /* 检查播放结束 */
        if (!g_midi_next) {
            if (g_midi_loop) {
                /* 循环: 重置到链表头 */
                g_midi_next = g_midi_msg;
                g_midi_msec = 0.0;
                tsf_reset(g_tsf);
                for (int ch = 0; ch < 16; ch++) {
                    tsf_channel_set_bank_preset(g_tsf, ch, (ch == 9) ? 128 : 0, 0);
                }
            } else {
                /* 非循环: 渲染完剩余衰减后静音 */
                out += block * 2;
                remaining -= block;
                if (remaining > 0) {
                    memset(out, 0, (size_t)(remaining * 2 * sizeof(short)));
                }
                return frames;
            }
        }

        out += block * 2;
        remaining -= block;
    }

    return frames;
}

/* 查询当前是否正在播放 */
int tsf_midi_is_active(void) {
    return (g_tsf && g_midi_msg) ? 1 : 0;
}

/* SF2 是否已加载 */
int tsf_midi_has_soundfont(void) {
    return g_tsf ? 1 : 0;
}

#endif /* OHOS_TSF_MIDI */
