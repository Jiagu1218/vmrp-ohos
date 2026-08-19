/* ohos_midi_tsf.h - TinySoundFont MIDI 合成桥接层声明。
 *
 * ohos_midi_tsf.c 的公开 API, 供 native_dsm_funcs.c 通过
 * OHOS_TSF_MIDI 宏条件调用。
 *
 * 许可证: MIT (与 TinySoundFont 一致)
 */

#ifndef OHOS_MIDI_TSF_H
#define OHOS_MIDI_TSF_H

#ifdef OHOS_TSF_MIDI

#ifdef __cplusplus
extern "C" {
#endif

/* 从内存加载 SF2 音色库。成功返回 1, 失败返回 0。 */
int tsf_midi_load_soundfont(const void *sf2_data, int sf2_size);

/* 从文件加载 SF2 音色库。成功返回 1, 失败返回 0。
 * 内部 fopen/fread 后调 tsf_load_memory。 */
int tsf_midi_load_soundfont_file(const char *path);

/* 自动搜索并加载 SF2 音色库。
 * 在 work_dir 下的 soundfont/ 子目录中搜索 .sf2 文件。
 * 典型路径: work_dir/soundfont/TimGM6mb.sf2
 * 找到第一个可加载的 SF2 即返回 1, 全部失败返回 0。
 * 已加载过则跳过(幂等)。 */
int tsf_midi_auto_load_soundfont(const char *work_dir);

/* 释放 SF2 资源 */
void tsf_midi_unload_soundfont(void);

/* 开始播放 SMF MIDI 数据。成功返回 0, 失败返回 -1。
 * 如 SF2 未加载返回 -2 (调用方应降级到上游合成器)。 */
int tsf_midi_play(const void *midi_data, int midi_size, int loop);

/* 停止播放 */
void tsf_midi_stop(void);

/* 暂停/恢复 */
void tsf_midi_pause(void);
void tsf_midi_resume(void);

/* 获取当前播放位置 (ms) */
int tsf_midi_position(void);

/* 获取总时长 (ms) */
int tsf_midi_duration(void);

/* Seek 到指定 ms 位置 */
int tsf_midi_seek(int ms);

/* 渲染 frames 帧音频到 buffer (S16LE 立体声交织)。
 * 返回实际渲染的帧数。 */
int tsf_midi_render(short *buffer, int frames);

/* 查询当前是否正在播放 */
int tsf_midi_is_active(void);

/* SF2 是否已加载 */
int tsf_midi_has_soundfont(void);

#ifdef __cplusplus
}
#endif

#endif /* OHOS_TSF_MIDI */

#endif /* OHOS_MIDI_TSF_H */
