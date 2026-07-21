# MUTICHANNEL 多声道音频修复 — OHOS_MUTICHANNEL_DISPATCH + OHOS_IMA_ADPCM

## 问题现场

MRP 游戏在 OHOS 真机上运行无音效。游戏通过 `mr_platEx(2222/2232/2242/2252)` 调用 MUTICHANNEL API 播放音效，原代码不识别 cmd 220-225，直接 fallthrough 返回 MR_IGNORE，导致音频播放完全被跳过。

## 根因分析

### 调用链

1. 游戏调 `mr_platEx(2222, ...)` → OPEN 音频设备
2. 游戏调 `mr_platEx(2232, ...)` → PLAY 音频
3. 上游 `dsm_media_platEx` 只处理 cmd 0-29，cmd 220+ 走 default → MR_IGNORE
4. 游戏认为 OPEN/PLAY 失败，无声音输出

### 为什么不能在 dsm_media_platEx 中修复

MUTICHANNEL OPEN 的 input 参数含 ARM 地址（`T_BG_PLAY_REQ{data(4B ARM addr), len, loop}`），需要 `arm_ptr()` 转换为宿主指针。但 `dsm_media_platEx` 位于 dsm.c，没有 `ArmExtModule` 上下文，无法调用 `arm_ptr()`。且 64 位宿主上 ARM 指针字段只有 4 字节，无法安全传递。

### 两个关键 bug

**Bug 1: device→type 映射偏移**

MUTICHANNEL API 的 device 编号与 `mr_playSound` 的 type 枚举不一致：

| MUTICHANNEL dev | 含义 | mr_playSound type | 枚举值 |
|---|---|---|---|
| 1 | MIDI | NATIVE_SOUND_MIDI | 0 |
| 2 | WAV | NATIVE_SOUND_WAV | 1 |
| 3 | MP3 | NATIVE_SOUND_MP3 | 2 |
| 4 | AMR | NATIVE_SOUND_AMR | 5 |
| 5 | PCM | NATIVE_SOUND_PCM | 3 |

初始实现将 `dev=2` 映射为 `type=2`（MP3），导致 WAV 音频数据被送入 MP3 解码器，minimp3 报 "no decodable frame" 后返回 MR_FAILED。

**Bug 2: IMA ADPCM 不支持**

MRP 游戏音效几乎全部是 IMA ADPCM 4-bit 编码的 WAV（fmt=17, bits=4），实测采样率 8000/11025/22050 Hz。原 `native_audio_play_wav` 直接调 `native_audio_set_pcm`，后者只支持 PCM fmt=1/3，IMA ADPCM 被拒绝返回 MR_FAILED。

## 修复方案

### 补丁 1: OHOS_MUTICHANNEL_DISPATCH（aex_table.c）

在 `aex_table.c` 的 `arm_ext_call_dispatch` 中直接拦截 platEx(220x-225x)，绕过 dsm_media_platEx：

- **220x/221x ALLOC_INRAM/FREE_INRAM**: 无操作，返回 MR_SUCCESS
- **222x OPEN**: arm_ptr 转换 data → malloc + memcpy 到静态缓冲 → 返回 handle=1
- **223x PLAY**: 从静态缓冲调 `mr_playSound(type, data, len, loop)`
- **224x STOP**: 按 type 调 `mr_stopSound(type)`
- **225x CLOSE**: 释放静态缓冲 + stopSound

关键设计决策：
- OPEN 只存数据，PLAY 才播放。v1 在 OPEN 时调 mr_playSound，异步播放导致 arm_ptr 内存失效
- handle 固定返回 1（简化单声道实现，同一时刻只支持 1 个活跃音频）
- device→type 映射使用正确偏移：`dev=1→0, dev=2→1, dev=3→2, dev=4→5, dev=5→3`

### 补丁 2: OHOS_IMA_ADPCM（native_dsm_funcs.c）

在 `native_audio_play_wav` 的 `native_audio_set_pcm` 调用前插入 IMA ADPCM 解码器：

```c
if (format == 17 && channels == 1 && bits_per_sample == 4 && block_align > 4) {
    // 解码为 S16 PCM → native_audio_set_pcm(pcm_buf, total_samples*2, loop, sample_rate, 1, 16, 1, 2)
}
// fallback: 原始 native_audio_set_pcm 路径
```

IMA ADPCM 解码参数：
- 每 block 首 4 字节: predictor(16bit LE) + step_index(8bit) + reserved(8bit)
- 后续每字节 2 个 4-bit nibble
- `samples_per_block = (block_align - 4) * 2 + 1`
- step_table[89] + index_table[16]（标准 IMA ADPCM 规范）

## 构建与部署

CMake 补丁通过 `scripts/CMakeLists.txt` 在 configure 时修改源文件，构建后 `:restore_patched` 恢复。因此：

1. **必须通过 `scripts/build_libvmpp_ohos.bat` 构建 native lib**，而非直接 `build_project`
2. 脚本流程: restore_patched → cmake configure(应用补丁) → ninja build → copy .so → restore_patched
3. 之后 `build_project` 打包 HAP（只打包 ArkTS 层 + 已有的 .so）

```bash
# 构建完整 HAP 的正确步骤:
scripts\build_libvmpp_ohos.bat          # 构建含补丁的 libvmrp.so
# 然后 DevEco Studio build + deploy
```

## 验证结果

```
OHOS_MC: OPEN dev=2 type=1 len=3900 loop=1 first4=52494646
OHOS_MC: WAV fmt=17 ch=1 hz=8000 bits=4
OHOS_MC: PLAY type=1 len=3900 loop=1 ret=0   ← MR_SUCCESS
```

- `type=1` (NATIVE_SOUND_WAV) 正确映射
- IMA ADPCM fmt=17 成功解码为 S16 PCM
- 真机 HUAWEI Mate 70 Pro 上音效正常播放

## 相关文件

- `scripts/CMakeLists.txt`: MUTICHANNEL 补丁(L680+) + IMA ADPCM 补丁(L347+)
- `vmrp/src/arm_ext/aex_table.c`: arm_ext_call_dispatch 拦截点
- `vmrp/src/native_dsm_funcs.c`: native_audio_play_wav(L643) + native_audio_set_pcm(L590)
- `vmrp/src/mythroad/dsm.c`: mr_playSound(L1325) wrapper → dsmInFuncs
- `vmrp/mrc/mrc_base.h`: MR_SOUND_TYPE 枚举定义

## 调试踩坑

1. **CMake 补丁不会在 `build_project` 中生效**：DevEco 的 CMake configure 不执行 scripts/CMakeLists.txt 的补丁逻辑，必须先用 bat 脚本构建 .so
2. **printf 诊断在 OHOS 上不可靠**：native 层 printf 需通过 hilog 前缀 `vmrp_core` 才能被 `hdc shell hilog` 捕获，否则静默丢弃
3. **OHOS hilog 格式**：整数值需 `%{public}d` 才能打印，普通 `%d` 输出为 `(private)`
4. **MRP 游戏同时走两条音频路径**：MUTICHANNEL(222x/223x) 传 RIFF/ADPCM + 传统 mr_playSound(3, same_data) 传 MP3 type → 后者报 "no decodable frame" 是正常的（同一段数据被两种方式播放）
