# optwar 突然加速1 BUG — 未修复说明

日期: 2026-08-05
状态: **未修复，停止尝试**
分支: analysize (基线保留)

## 问题

`pnpm vitest run test/e2e/optwar/game-play.test.ts -t 突然加速1`

| 阶段 | 结果 |
|------|------|
| 基线 fps | ~9.7 |
| 加速期 fps | ~30-35 (≈3× 倍速) |
| 测试期望 | resumedDrawRate / normalDrawRate ∈ [0.5, 1.5] |
| 测试实际 | resumedDrawRate / normalDrawRate ≈ 3.0+ |

## 根因 (确认)

加速链：
1. 取消支付 (KEY 事件) → wrapper helper 关闭广告子模块 (modal suspend_depth: 1 → 0)
2. wrapper 在 dispatch resumeApp (game helper code=5) 前把 mr_state 写为 MR_STATE_RESTART(3) (cfunction.ext @ 0xE836D8)
3. game 0x229D9C (resumeApp handler) 调 0x236998(interval=10) 试图把 frame timer 改成 10ms
4. mrc_timerStart 第一行检查 `mr_state == MR_STATE_RESTART || MR_STATE_STOP` 命中，丢弃插入
5. frame timer 保持初始 100ms ✓

模拟器失败链：
1. 模态关闭回调 → 调用 game helper (code=1 wrapper->code=5)
2. **模拟器没有 wrapper 状态门前置，mr_state 是 RUN(1)**
3. game 0x229D9C 调 0x236998(interval=10) 写入成功
4. frame timer 从 100ms → 10ms 永久保持
5. game 逻辑按 tick 计数驱动 (0x229DE4 每拍+1) → 持续 4× 加速

## 尝试的修复路径 (4 个全部失败)

### 路径 A: 在 arm_ext_call(code=5) 入口设 mr_state=3

```c
if (code == 5 && m->primary_p_addr && has_separate_wrapper) {
    mr_state_saved = mr_state;
    mr_state = 3;
}
```

**失败原因**: 加速不是由 game helper code=5 触发，而是由 wrapper code=2 处理 timer queue 时通过 `mr_timerStart(10)` 触发。code=5 helper 调用从未出现。

### 路径 B: 在 arm_ext_call(code=2) 入口设 mr_state=3

```c
if (code == 2 && m->modal_mr_state_guarded) {
    mr_state = 3;
}
```

**失败原因**: wrapper 的 `wrapper_rw[0x5C][0x08][0]` 状态字段映射不明。设 native `mr_state` 全局变量后, wrapper 内部 mrc_timerStart (0xE847DC) 读的是 wrapper RW 内的独立状态字段，与 native 全局变量不同步。设置无效。

### 路径 C: 在 aex_t031 hook 检查 mr_state 并钳 t<100 的 interval

```c
if (m && m->modal_resume_recent) {
    if ((uint16)r0 > 0 && (uint16)r0 < 100) r0 = 100;
}
```

**失败原因**: mr_timerStart(10) 由 wrapper 内部处理 timer queue 时通过 `wrapper_rw[0x5C][0x5C+0x10]` 间接调用。但实际查证后, 该字段是 wrapper 自己的 RW 区内的 GOT 指针, 不是 native `mr_state`。修复路径的"延迟生效窗口"猜测可能错位 (modal_resume_recent 在 arm_ext_call code=2 第一次时被清, 但实际触发 t=10 的 code=2 调用发生在 wrapper helper 内部处理 timer queue 时, modal_resume_recent 可能已被清)。

### 路径 D: 在 modal 关闭时直接修改 wrapper RW 字段

```c
uint32_t wrapper_rw = 0;
if (m->p_addr) memcpy(&wrapper_rw, arm_ptr(m, m->p_addr), 4);
uint32_t mr_state_iface = 0;
if (wrapper_rw) memcpy(&mr_state_iface, arm_ptr(m, wrapper_rw + 0x5Cu + 8u), 4);
if (mr_state_iface) {
    uint32_t v = 3;
    memcpy(arm_ptr(m, mr_state_iface), &v, 4);
}
```

**失败原因**: 未经验证 wrapper RW 0x5C 字段的实际语义。wrapper 内部反汇编只显示 `[wrapper_rw+0x5C][0x08][0]` 是某个状态字段, 但字段的真实映射 (是 mr_state slot 还是其他) 需进一步反汇编追踪。本次任务无法在合理时间内确认。

## 第三方代码交叉验证

| 真机语义 | 模拟器缺失 |
|---------|-----------|
| wrapper dispatch resumeApp 前设 mr_state=3 (0xE836D8) | 模拟器没有 wrapper 状态前置 |
| game 0x236998 状态门丢弃 mr_state ∈ {3, 4} (0x2369C2) | 模拟器不命中 (mr_state=RUN) |
| mrc_timerStart 第一行检查 mr_state (mrp_core.c:184-187) | 模拟器 mr_timerStart 直接通过 table[31] |
| wrapper 0xE847C4 mrc_timerStart 检查 wrapper_rw[0x5C][0x08] | 模拟器跳过 wrapper 前置检查 |

## 文档与已知互斥

之前已经验证 4 个 host 端修复路径**全部互斥** (见 [[optwar-resume-speedup-mutex-issue]]):
- 释放 wrapper timer owner → 破坏 advbar 下载/启动
- 替换 closed_child_p 判据 → 仍破坏 advbar
- aex_table.c t<50u 覆盖 → 与 ownerResume 触发顺序冲突
- 移除 modal_entered_by_timer → advbar 5/5 稳定通过但 test 1 偶发

本次新增 4 个路径同样不工作，且路径 D 涉及更深 wrapper ABI 字段映射, 超出本次任务范围。

## 结论

optwar 突然加速1 是已知未修复 BUG。基线保留 (4b3a2c9 fix: optwar广告插件交互卡顿 不变)。文档/记忆已记录根因, 待后续子任务:
1. 验证 wrapper RW 0x5C 字段与 native mr_state 的真实映射关系
2. 或在 wrapper code=2 处理前后增加针对 frame timer 的语义化识别 (非硬编码 optwar-specific 节点)

## 复现命令

```bash
pnpm vitest run test/e2e/optwar/game-play.test.ts -t "突然加速1"
```

artifact 默认清理 (test/e2e/engine-e2e.ts:122)。需要保留用:

```bash
VMRP_E2E_KEEP_TMP=1 pnpm vitest run test/e2e/optwar/game-play.test.ts -t "突然加速1"
```

带 TEMP-DIAG (会产生大量日志, 仅用于取证):

```bash
SKYENGINE_ARM_EXT_TIMER_OWNER_DIAG=1 SKYENGINE_ARM_EXT_TIMER_LIVENESS_DIAG=1 VMRP_E2E_KEEP_TMP=1 pnpm vitest run test/e2e/optwar/game-play.test.ts -t "突然加速1"
```

## 2026-08-05 11:17 关键诊断: wrapper 状态门字段语义

加入 `TEMP-DIAG wstate` 在每次 aex_t031 调用后 dump 关键字段:

```
wrapper_rw = 0x225E60
wrapper_rw[0x5C] = 0x25E858D     # 不是 mr_state_slot (mr_state_slot = 0x200140)
wrapper_rw[0x5C][+8] = 0x6C925100  # 链第二步是无效地址
wrapper_rw[0x5C][+8][0] = 0x0      # 链第三步读 0 (state)
mr_state_native = 1              # native mr_state 是 RUN
mr_state_slot_val = 1            # mr_state_slot 写入 RUN
```

**关键发现**:
- `wrapper_rw + 0x5C + 8 = 0x225EC4` 在 P RW 范围内 (P.RW_len = 0x518)
- 但 `[wrapper_rw+0x5C]` 实际值是 `0x25E858D` (heap 分配的结构体)
- 不是 `mr_state_slot` (mr_state_slot = 0x200140)
- wrapper 0xE80260 init 路径把 `mr_table[0x2C]` (= mr_printf 函数指针) 复制到 wrapper_rw[0x5C]
- 所以 wrapper_rw[0x5C] = mr_printf 函数指针, 不是 mr_state 字段

**结论**:
- wrapper 状态门 `[wrapper_rw+0x5C][+8][0]` 实际 deref `mr_printf` 函数指针 + 8 字节 + 0 字节
- 这是无效 deref (普通函数指针没有 +8 字段)
- 模拟器读到 0, wrapper 状态门实际**从未命中**
- native mr_state 与 wrapper 状态门读取的字段**完全无关**

**修复方向冲突**:
- 设 native mr_state = RESTART → wrapper 状态门看不到 (仍读 0)
- 设 wrapper_rw[0x5C][8][0] = 3 → 但 `[wrapper_rw+0x5C][8]` 是无效地址 (0x6C925100), 设置会失败

**wrapper 反汇编状态门 (0xE847DC-0xE847E8) 实际是个永远不命中的检查**, 因此模拟器 wrapper mrc_timerStart 内部不依赖这个状态门。

**真正修复路径 (重新审视)**:
- modal 关闭后第一次 wrapper code=2 timer 处理时, 把 `mr_timerStart(10)` 钳到 `mr_timerStart(100)`
- modal_resume_recent 窗口需要对齐 wrapper timer queue 处理时机
- 此路径不依赖 wrapper 状态门, 不破坏其他场景的合法 10ms

## 2026-08-05 11:30 停止分析

未实施修复, 进展已保存到本文档与 memory.
## 2026-08-05 18:00 真机 wrapper 完整时序 (新分析)

**精确字段映射** (从 mrc_helper.h 字段顺序推导 + 模拟器 _mr_c_internal_table 布局):
- `mr_table[0x5C]` = `_mr_c_internal_table` 指针
- `_mr_c_internal_table[8]` = `mr_state` 指针 (指向 mr_state_slot, alloc_u32_slot 分配的 4 字节槽)
- `mr_state_slot` 存当前 `mr_state` 值

**wrapper 状态门** (cfunction.ext @ 0xE847C4 `mrc_timerStart`):
- 读 `mr_table[0x5C][8][0]` = `mr_state_slot` 当前值
- `mr_state == 3 (MR_STATE_RESTART)` 或 `== 4 (MR_STATE_STOP)` → 拒绝插入, 返回 -1
- 否则 → 正常插入

**game 0x236998 状态门** (game.ext frame timer 编程函数):
- 同样读 `mr_table[0x5C][8][0]` = `mr_state_slot`
- `mr_state == 3 或 == 4` → 拒绝 (返回 -1)
- 否则 → 接受

**关键: wrapper 0xE8363C (`mrc_mr_state`) 完整路径** (在 `code=1` KEY 事件处理时被调):

```
0xE8363C-0xE8364A: 读 mr_state, 检查 == 1 (RUN) 或 == 2 (PAUSE)
                     都不是 → 直接跳 0xE83704 返回
0xE8364C: bl 0xE83714 (mrc_mr_timer_pause)
0xE83650-0xE8365A: 清 wrapper 全局 paused flag + 检查 timer pause
0xE8365C-0xE836B8: 清 *mr_timer_p = 0, 清 *mr_timer_state = 0
0xE836BA-0xE836C6: 写 *mr_timer_p = handler_addr (timer 回调)
0xE836C8-0xE836CC: 调 mr_timerStart(100) ← 关键: 此时 mr_state 还是 1
0xE836D0-0xE836D6: 写 *mr_timer_state = 1 (RUNNING)
0xE836D8-0xE836E0: 写 *mr_state = 3 (MR_STATE_RESTART) ← 关键
0xE836E2: b.n 0xE836F4
0xE836F4-0xE83702: 调 mrc_helper_resume, 清 wrapper 内部变量
0xE83704: 返回
```

**真机时序关键点**:
- `mr_timerStart(100)` 在 `mr_state=1` 时调 → 100ms 接受
- `*mr_state = 3` 之后 game helper 0x229D9C 设 10ms → 0x236998 看到 `mr_state=3` → 拒绝
- `mrc_helper_resume` 调 game helper code=1? 实际可能调 `mrc_extHelper(code=1)` 让 game 处理 KEY 事件, game 内部 0x229D9C 拒绝 10ms
- **wrapper 0xE8363C 处理完 mrc_helper_resume 之后, wrapper code=1 路径继续到 0xE834FA 调 game helper code=1** (0xE8352E blx r6)

**关键疑问**: 0xE8363C (`mrc_mr_state`) 在 code=1 路径, **设置 mr_state=3 是在 game helper code=1 之前**。但 game helper code=1 处理时 `mr_state=3` 持续。

**wrapper 0xE8363C 没有清回 mr_state=1**! 所以 `mr_state=3` 持续到下次 `mrc_mr_state` 被调 (下次 code=1 事件)。

**那真机怎么 work**? `mr_state=3` 让 game 0x229D9C 设 10ms 失败。但 game 0x229D9C 是 `mrc_resumeApp` handler, **只在 modal 关闭后第一次 code=1 调**。后续 game normal flow 用 `mr_state=1`, game 自己的 100ms frame timer 来自 `mrc_init` 设的最初 100ms (code=0 调一次), 之后 game 自己不调 `0x236998`. 100ms 是 `mrc_init` 时设的**永久** interval=100.

**真相**: game 0x236998 只在 `mrc_resumeApp` (modal 关闭后) 调一次, 把 frame timer 从 100 改成 10. 之后 frame timer 永久 10ms (除非再调 0x236998 改 interval).

**wrapper 0xE8363C 写 mr_state=3 拒绝这次 10ms 插入, 保持 100ms**! 之后 `mrc_mr_state` 持续 `mr_state=3` 不影响 (因为 game 不再调 0x236998).

**所以真机 mr_state=3 持续是 OK 的, 因为 game 0x229D9C 只在 modal 关闭瞬间调一次**.

**模拟器修复失败原因**: 我在 arm_ext_call 入口临时设 `mr_state=3`, **整个 arm_ext_call 期间** (game helper + wrapper 后处理) 都设 3. 但**整个期间**包括 game helper code=1 设的 100ms 后续 timer (modal 关闭后 game 调 100ms), 这些也被钳.

**真正的修复需要**: 模拟器在 `arm_ext_call(code=1)` 期间设 `mr_state=3`, 但**只让 0x229D9C 看到 mr_state=3** (即 wrapper code=1 → game code=1 这段时间). game code=1 完成后立刻回滚.

**但模拟器无法区分 wrapper 内部调用 game helper 和后续 wrapper 后处理**. 所以**这修复需要更细粒度的状态机**.

**或者**: 钳 t=10 (而非 t<100). 但这破坏其他场景的合法 10ms.

**结论**: 修复需要更深入的 wrapper ABI 改造, 超出本次任务范围.

## 2026-08-05 18:50 最终总结 (基于 third_party MTK 反汇编)

### 关键字段映射 (MTK disasm 验证)

`third_party/mtk_disasm/DECOMPILATION_ANALYSIS.md` 第 89 行明确:
```
base[0x04] = mr_state  // _mr_c_internal_table[2]
```

`base[0x08] = bi` (flags), `base[0x0c] = mr_timer_state` 等. 与模拟器 `internal[17]` 数组布局**完全一致**:
- `[0] = mr_m0_files_addr`
- `[1] = vm_state_slot`
- `[2] = mr_state_slot` ← **关键! 模拟器已正确映射到 arm 内存**
- `[5] = mr_timer_state_slot`
- ...

### MTK disasm 验证真机时序

`_mr_TestCom(801, ..., 5)` = `mrc_resume()`:
1. `mr_state == MR_STATE_PAUSE` → `mr_state = MR_STATE_RUN` (从 2 改 1)
2. 调 `mr_resumeApp_function()` (Lua)
3. 调 `native_ext_void_event(5)` → `mrc_extHelper(5)` → wrapper helper 入口 (0xE800B0)
4. wrapper 内部处理 code=5 → 调 `mrc_resume` (0xE83220)
5. **wrapper 0xE8363C `mrc_mr_state` 在 code=1 (KEY 事件) 被调**, 不是 code=5

### wrapper `mrc_mr_state` 完整时序 (最终)

```
0xE8362C-0xE8364A: 读 mr_state, 检查 == 1 (RUN) 或 == 2 (PAUSE)
0xE8364C: bl 0xE83714 (mrc_mr_timer_pause)
0xE8365C-0xE836B8: 清 mr_timer_p = 0, 清 mr_timer_state = 0
0xE836BA-0xE836C6: 写 mr_timer_p = handler_addr (game helper)
0xE836C8-0xE836CC: 调 mr_timerStart(100) ← 此时 mr_state = 1
0xE836D0-0xE836D6: 写 mr_timer_state = 1 (RUNNING)
0xE836D8-0xE836E0: 写 mr_state = 3 (MR_STATE_RESTART) ← 关键!
0xE836F4-0xE83702: 调 mrc_helper_resume, 清 wrapper 内部变量
0xE83704: 返回
```

**`mr_state=3` 持续到下次 `mrc_mr_state` 被调 (下次 code=1 事件)**. 但 game 0x229D9C (`mrc_resumeApp`) **只在 modal 关闭后第一次 code=1 调一次**, 后续 game 用 100ms (永久 interval, 不再调 0x236998).

### 为什么模拟器修复失败

1. **设 `mr_state=3` 必须精确对齐 wrapper 0xE8363C 调用时机**:
   - 模拟器不执行 wrapper 内部反汇编, 必须在 arm_ext_call 入口**手动**设 3
   - 但**整个** arm_ext_call 期间 (game helper + wrapper 后处理) 设 3, game 后续 100ms timer 也会被钳

2. **`mr_state=3` 影响范围比预想大**:
   - 真机 `mr_state=3` 在 code=1 helper 内, game 0x229D9C 设 10ms 被拒 (符合预期)
   - 但模拟器在 arm_ext_call 整个期间设 3, game **后续 code=2 helper 调** 100ms timer 也被钳
   - game 渲染停止 (draw_count 卡在 3118 帧)

3. **`mrc_mr_state` 还做 `mr_timer_p=0` 等副作用**:
   - 真机清 `mr_timer_p=0` 让后续 timer 调度从 helper 重新走
   - 模拟器只设 `mr_state=3` 不模拟这个副作用, game 流程仍然错乱

### 结论

**修复需要**: 在 `arm_ext_call(code=1, modal_resume_recent)` 期间:
1. 入口设 `mr_state=3`, 清 `mr_timer_p_slot=0`
2. **仅在 game helper code=1 回调返回后** 立刻回滚 `mr_state=1` (`mr_timer_p_slot` 不回滚, 走 wrapper 内部实际逻辑)

这需要更细粒度的状态机改造. wrapper 内部还有调 `mrc_mr_state_check (0xE84FF4)` 在 `mr_state==1` 时跳 0xE8362C 设 `mr_state=3` — 模拟器在 `mrc_mr_state_check` hook 设 3 + 调完回滚, **仅持续一次 helper 调用**.

**但** wrapper 0xE84FFA 的 call 在 wrapper 整个执行期间**未被触发** (SKYENGINE_ARM_EXT_WATCH_PC=4FFA 显示 0 次). 模拟器**未执行** wrapper 内部 mrc_mr_state_check 路径. 所以 `mr_state=3` **从未被设**.

### 真机 working 而模拟器 broken 的根因

真机 wrapper 内部执行 0xE8341E `mrc_helper` → 0xE8343E-0xE83442 `blx r1` (调 mrc_mr_state_check 或类似回调, 取决于 `mr_state` 值). 模拟器不执行 wrapper 内部反汇编, 所以 mrc_helper 内部分发逻辑没跑, `mr_state=3` 从未被设.

### 最终建议

修复需要**模拟 wrapper 内部反汇编执行** — 这超出当前 skyengine 模拟器架构能力. 或者**仅在 modal 关闭后第一次 code=1 helper 调用入口 + 出口精确设/清 `mr_state=3`**, 但 game 0x229D9C 拒绝 10ms 后续 game 自己不调 0x236998, game 100ms 永久生效. 这需要确认 game 不会在 modal 关闭后调其它 10ms 编程函数.

**当前任务无法完成修复. 保留详细分析供后续子任务使用.**

## 2026-08-06 续查审计

- 当前分支 `430307e` 已删除 `突然加速1/2`，所以用户给出的 `-t 突然加速1`
  命令在未恢复测试时没有行为覆盖，不能作为修复证据。
- 从删除提交的父版本恢复 `突然加速1`，并保留进入广告/支付插件、取消、
  返回游戏菜单、返回游戏画面后分别测量 7 秒全窗与最后 2 秒绘制速率的链路。
- 现有 TEMP-DIAG 仍只受 `SKYENGINE_ARM_EXT_TIMER_OWNER_DIAG` 控制；先用
  默认日志建立失败基线，再按需开启，避免重复产生大体积 trace。
- 已复核 `/tmp/optwar-wrapper-analysis` 的既有二进制与反汇编：game.ext
  `0x229D9C` 的 resume 路径把同一帧节点设为 10ms，初始化
  `0x22AE1C` 只设过一次 100ms；`0x236998` 在 ARM 可见 `mr_state` 为
  RESTART(3) 或 STOP(4) 时拒绝重挂。下一步必须用恢复后的真实用例重新
  验证这条链，不把历史推断直接当成当前修复依据。

## 2026-08-06 holder/record 精确取证与旧结论作废

### 稳定复现与画面有效性

- 无高频 trace、只启用精确 PC watch 的运行结果为：支付前基线
  `9.987 draws/s`，返回后完整 7 秒 `33.903 draws/s`，最后 2 秒
  `36.965 draws/s`；产物保存在 `/tmp/skyengine-e2e-IQgSfT`。
- 四轮独立基线的正常均值为 `9.993512 draws/s`，返回后完整窗口均值为
  `32.687644 draws/s`，最后 2 秒均值为 `34.324837 draws/s`。
- PPM 关键像素 `(22,314)` 始终为 `[200,252,248]`，相邻验证帧约有
  5--6 万像素差异。故失败不是冻结、单次追帧或离开游戏场景，而是持续
  以约 3.3 倍速运行。

### wrapper 返回链定案

精确 watch 记录：

```text
E80C30 holders: 0x2BCB70, 0x2BC798, 0x2BC388
E80C6C holders: 0x2BCB70, 0x2BC798, 0x2BC388
E83DAC records: 0x2BCECC, 0x2BCAF4, 0x2BC71C (game)
```

当前支付插件取消路径的实际执行链为：

```text
0xE81208 -> 0xE81240 -> 0xE80C6C
           holder[0x0c]: 1 -> 0
         -> 0xE83DAC
         -> record[8](record[0x1c], 5, 0, 0)
         -> game 0x229D9C
         -> game 0x236998(same_node, 10, ..., repeat=1)
```

因此 code=5 是 wrapper 在真实 suspend `0 -> 1` / resume `1 -> 0`
边界上的确定行为；game 与 smsend/advbar holder 对称出现，不能把 game
从 holder 列表移除，也不能通过释放 timer owner 或宿主抑制 code=5 绕过。

### 作废旧结论

- `0xE83E38` 的确是 silent resume，但只由另外两条 teardown 路径调用；
  当前 `0xE81240` 无条件进入 `0xE80C6C -> 0xE83DAC`，不存在可修正的
  loud/silent 条件分支。
- `0xE84FF4` 是 `0xE84FB0(flag, delay)` 创建的私有 wrapper timer
  callback，静态创建点只有 `0xE81DBE/E81DC8/E8267E`；当前 modal close
  路径既不创建也不执行它。wrapper 基址下 `0xE8362C/0xE836D8/
  0xE84FF4/0xE84FFA` 动态命中均为 0，其他模块的相对偏移命中只是地址
  碰撞。
- `0xE8341E` 是异步结果 callback thunk，不是此前所称的 helper
  dispatcher。故本文前面的“wrapper 先写 `mr_state=3`、再拒绝 game
  的 10ms resume timer”解释已被反汇编和运行时证据推翻，不能作为修复
  依据，也不能伪造 `mr_state=3`。

### game timer 语义

game 初始化路径调用 `0x236998(node, 100, ..., repeat=1)`；resume 路径
对同一节点调用 `0x236998(node, 10, ..., repeat=1)`。节点布局为：

```text
+0x00 magic 0x79ABBCCF
+0x04 period
+0x08 remaining delta
+0x0c callback
+0x10 data
+0x14 repeat
+0x18 next
```

walker 在 repeating 节点到期后以 `r1=0` 重挂，因此沿用节点 `+0x04`
中的 period。resume 对同一节点的调用同时把 remaining delta 和 period
改为 10ms，造成首次恢复之后的所有重挂都永久变成 10ms。

SKY 参考实现使用平台单实例 one-shot timer，start 前停止旧 timer，且不
钳制 10ms；`mr_getTime` 是系统单调毫秒。因此全局 interval clamp、修改
时钟、追帧补偿或把插件切换映射成整 VM pause/resume 都没有契约依据。

### 当前待验证假设

唯一仍符合结构边界的实验是：在真实 suspend `0 -> 1` 时，保存当时 game
timer head 所指 repeating 节点的 period；在对应 resume `1 -> 0` 回调
结束后，仅当节点 identity、magic 和 repeat 属性仍匹配时恢复该节点的
period，而不改 callback 在 `+0x08` 写下的首次 remaining delta。这样可
保留立即首拍，同时让 walker 后续按暂停前周期重挂。

该实验不得检查应用名、代码地址或具体毫秒值。但它仍可能覆盖 guest 在
resume 中有意修改 repeating period，尚缺 SKY/SDK 契约支持；必须先做
独立语义审计，并以兼容用例验证，不能把它当作兜底逻辑直接合入。

## 2026-08-06 最终语义审计

### loud close 与 silent bookkeeping 的完整顺序

新增窄 watch 运行产物 `/tmp/skyengine-e2e-pBtvAI`，测试结果为：

```text
baseline=9.982 draws/s
resumed=34.235 draws/s
tail=34.473 draws/s
```

wrapper 基址下的关键调用顺序为：

```text
E81208 r0=2 r1=2 r2=0, LR=E81CC1
  -> E81240 -> E80C6C -> E83DAC  (sends code=5)
  -> E81240 -> E80C6C -> E83DAC  (sends code=5)
  -> E81240 -> E80C6C -> E83DAC  (sends game code=5)
E80F2C
  -> E83E38  (silent bookkeeping release for the same three records)
```

这修正了上一节对 silent resume 的简化描述：当前关闭流程在 loud holder
resume 之后确实还执行 `E80F2C -> E83E38`，但 silent 路径不是 loud 路径
的条件替代，也不会撤销已经发送给 game 的 code=5。两段代码均由原始
wrapper ARM 二进制执行；宿主没有合成、重复发送或提前清零 holder 深度。

### “恢复旧 period”实验被否决

两项独立审计均确认 `0x236998` 的非零 interval 参数具有明确的永久重配置
语义：

```text
0x2369e4  if (r1 != 0)
0x2369e8      node[+4] = r1
...
0x236a12  node[+8] = node[+4]
```

MRC SDK 的 `mrc_timerStart` 参考实现同样先以非零参数更新 `time`，再把
`left` 重置为 `time`。公开 API 另有 `mrc_timerSetTimeEx` 可只改 period；
若应用想表达“首次 10ms、后续仍 100ms”，必须自行再调用该 API。平台和
wrapper 都不会自动执行这一步。

因此按 suspend/resume 边界保存并恢复旧 period 虽能制造
`left=10, period=100` 的合法混合状态，却等价于宿主凭空注入一次
`mrc_timerSetTimeEx`。结构判据无法区分 optwar 与合法的“恢复后提高帧率”
应用，也无法从多个 repeating 节点中通用指定所谓 primary frame timer。
该方案属于兼容兜底，违反本任务约束，未实施。

### SKY 平台契约结论

- MTK/SPRD 平台只接收当前 outer one-shot delay；它看不到 MRC 内部节点、
  repeat period 或 primary timer 身份。
- 非零 `mrc_timerStart` 会替换同一节点的 period 和 remaining delay；10ms
  合法，平台不钳制。
- MRC pause/resume 契约只保证回调顺序。VM 级 resume 的 300ms timer 是
  callback 未自行重启 timer 时的 fallback，与本次 wrapper 内部插件关闭
  无关。
- 当前 wrapper 正确发送一次 game code=5，game 明确把同一 repeat 节点从
  100ms 改为 10ms，之后没有任何恢复 100ms 的 guest 路径。

在“禁止应用/地址/interval 特判、禁止兜底、最小修改、遵循 SKY 契约”的
约束同时成立时，没有宿主源码修改既能把该 guest 的明确 10ms 请求改回
100ms，又不改变其他应用的合法 timer 语义。若产品仍要求该样本保持原速，
必须明确放宽一项约束：允许隔离的兼容策略，或允许修补该 MRP 自身的
resume timer 参数。核心模拟器不应把其中任一方案伪装成平台修复。

本轮加入的 wrapper legacy queue、table[31] interval 诊断已经删除；通用
`VMRP_ARM_EXT_WATCH_PC` 设施保留，因为它不是本问题新增的临时代码。

### 清理后验证

```text
cmake --build build --target skyengine --parallel
  -> [100%] Built target skyengine

pnpm vitest run test/e2e/optwar/game-play.test.ts -t 突然加速1 --retry=0
  -> baseline=9.983, resumed=35.036, tail=38.454
  -> failed at resumed <= baseline * 1.5
```

最终复现未设置 PC watch、timer owner 或 timer liveness 诊断环境变量，产物
为 `/tmp/skyengine-e2e-s1ohDs`。该结果确认删除 TEMP-DIAG 后问题和证据链
均不变；因为没有满足约束的修复，未继续运行整套兼容回归。

## 2026-08-06 table[131] 与状态同步边界审计

### host 日志与 guest watch 对 dump0 整区 cache-sync 的观测不一致

使用现有 `SKYENGINE_ARM_EXT_DIAG=1` 执行一次窄化复现，产物为
`/tmp/skyengine-e2e-s0opVl`，结果为：

```text
baseline=9.996 draws/s
resumed=34.761 draws/s
tail=36.982 draws/s
```

这次 host `aex_t131` 日志只记录了四次 table[131] command 9：

```text
0x2263A0 / 96268  internalLoader=1  game.ext
0x23FF10 /  5880  internalLoader=1
0x241F40 / 52548  internalLoader=1
0x24FE68 / 20916  internalLoader=1  支付前台 child
```

这组 host 日志没有记录 modal 关闭边界的整区调用。但是另一组窄 guest PC
watch 在 `table[44]` 把 614400 字节 dump 恢复后明确观察到：

```text
table[131](0, 9, 0x226380, 0x96000), LR=0xE84637
```

两种观测为何不一致仍未解释，不能据单次 host 日志断言 guest 没有执行
整区 cache-sync。该差异不改变本问题的因果结论：即使以上整区调用进入
当前 `aex_t131`，`internalLoader=0` 且 `lastFile` 只有 392 字节，两条
payload copy 分支都不成立；primary-covering 分支只做 stale-module
reconciliation、清 pending staging、校验不变量和 TB invalidation。
command 9 没有任何分支写 game timer 的 period/remaining/repeat，也不调用
lifecycle/helper。因此它仍不能直接造成已由 `0x229DB4 -> 0x236998` 证明的
`100 -> 10` period 写入。

### host/guest state slot 同步不会修改 timer period

`sync_internal_state_to_arm()` 在每次 ARM callback 前只把 host
`mr_state`/`mr_timer_state` 发布到两个独立 internal slot；
`sync_timer_state_from_arm()` 在 callback 后只导入 timer 的
idle/running 状态，不读写 wrapper 或 game 定时器节点。目标运行中
host 始终保持 `mr_state=RUN`，没有 restart/stop handoff；该同步边界
不能解释 node period 从 100 变成 10。

### 关闭拍的实际 queue 内容

modal depth 从 1 降到 0 的同一 wrapper code=2 callback 中，旧前台
child 的 1ms teardown node 被消费；随后 wrapper legacy queue 显示：

```text
head = 0x2BCB30
next = 0x2BC758
game holder/timer node = 0x2BC758
outer rearm sequence = 1000ms -> 10ms -> 10ms
```

下一拍首先还有一次 990ms 剩余节点计算，然后持续变为两次
10ms rearm。第一个 10ms 请求的 `r6=0x2BC758`，与已反汇编证明的
game timer node 一致。这排除了“table[131] 恢复了错误 arena”和
“host state slot 覆盖了 guest 状态”两个方向，也再次确认 host 看到的
10ms 来自 guest queue 本身。

### 历史修复的矛盾需要重验

历史分支 commit `1a1befc` 曾通过在精确 modal close 边界释放
wrapper timer owner，并让下一拍经 primary public helper 路由，使同名
用例回到约 100ms 节奏。它的旧根因说明“wrapper cleanup 重放并饿死
primary”已被本轮指令级证据否定：当前 wrapper 每拍确实消费
game node，没有饿死。但“同一用例曾经通过”本身是新的反证，所以
下一步只重验该 patch 改变了哪一个 guest 可见路由/节点状态；若无
SKY 契约或通用结构不变量支持，不会因为它偶然降速就恢复该旧逻辑。

## 2026-08-06 历史 ownerless patch 重验与否决

### 隔离 A/B 证明降速效果真实

子 Agent 在 detached worktree 中用 commit `1a1befc` 自身的源码、fixture、
harness 和锁定的 Vitest 3.2.6 重建，并以其父提交 `cd18b48` 作为只替换
binary 的对照。两边使用同一测试流程且都到达相同支付/返回画面：

```text
1a1befc:  baseline=9.977, resumed=8.506, tail=8.452  PASS
cd18b48:  baseline=9.990, resumed=37.162, tail=36.923 FAIL
```

因此旧 patch 的效果不是测试重命名、fixture 变化或历史日志误读。不过
返回后约 `0.85x` 只是在 `0.5x..1.5x` 容差内，并未证明严格恢复 `1.00x`。

### 当前二进制上的指令与路由证据

临时重施同一机制后的两次无 PC-watch 运行分别得到：

```text
/tmp/skyengine-e2e-GD5gXg: baseline=9.990, resumed=8.421, tail=8.498
/tmp/skyengine-e2e-ouv8CZ: baseline=9.996, resumed=7.986, tail=6.492
```

后一组启用了 timer-owner 诊断，关闭边界为：

```text
code=2 foreground=1 wrapperLive=1 primaryLive=1
timerP=wrapperP timerH=wrapperH
```

精确 PC watch 同时确认 patch 生效前的同一个 callback 内仍完整执行：

```text
game code=5
0x229DB4 -> timer_set(node, 10)
0x2369E8 -> node.period = 10
```

随后 repeat walker 仍以 interval zero 重挂同一节点，故 guest period 始终
是 10。patch 唯一的行为是在 ARM callback 返回后清除 host
`timer_p_addr/timer_helper_addr`，它不可能撤销已经完成的节点写入。

ownerless 并不是中性状态。`mr_timer()` 先调用
`arm_ext_primary_helper()`；此时该函数返回 0，继而
`native_ext_void_event(2)` 调 `arm_ext_call(code=2)`。因没有 owner，
`arm_ext_call` 的默认生命周期路由直接选择 primary public helper：

```text
real wrapper-owned expiry -> wrapper helper -> wrapper queue

变为

host recovery expiry -> ownerless -> primary public helper
```

没有一次进入 `arm_ext_call_primary_compact_dispatch()`。primary helper 在
该路径内停止 host timer，而现有 modal recovery 逻辑又用固定 100ms
`mr_timerStart(100)` 补启并继续保持 ownerless。于是持久 10ms guest 节点
没有按其真实 wrapper queue 调度，只由约 100--120ms 的 synthetic recovery
拍间接产生可见绘制，解释了约 8.5 draws/s 的通过结果。

### 不存在支持该转移的 SKY/结构不变量

SKY/MRC 可证明的所有权规则只有：outer timer 到期应回到编程该 delay 的
scheduler/module。本路径中的 wrapper 正是 outer scheduler：其队列包含
primary record，它计算下一次 outer delay，并通过 child trampoline 分发
game node。关闭时 wrapper queue 存活是合法后续工作证据，不是 stale owner
证据；primary 内部 queue 同时存活也不能推导 timer 所有权应被丢弃。

仓库中的 `docs/optwar-advbar-return-stall.md` 还记录了该判据的反例：相同
ownerless 机制会饿死仍承载下载/启动 timer 的合法 wrapper queue。历史
提交关系也不是 `4b3a2c` 直接 revert `1a1befc`；同树的 reparented
`81aae96` 后来被主线历史排除，且后续 ownerless 实验因上述 stall 回滚。

结论：历史 patch 通过测试是以 100ms recovery fallback 替换真实 wrapper
调度并掩盖 10ms guest period，不是 timer 修复。它违反“无兜底”和 timer
owner 契约，不能作为最终实现；本轮重施的字段、分支和临时
`DIAG modal_close` 已全部删除。

### 回滚实验后的最终干净基线

源码恢复真实 wrapper timer owner 后重新构建并在没有任何 ARM diagnostic
环境变量的条件下执行目标：

```text
cmake --build build --target skyengine --parallel
  -> [100%] Built target skyengine

pnpm vitest run test/e2e/optwar/game-play.test.ts -t 突然加速1 --retry=0
  -> baseline=9.991, resumed=34.296, tail=36.472
  -> FAIL: resumed > baseline * 1.5
```

此前保留的失败产物 `/tmp/skyengine-e2e-IQgSfT` 与
`/tmp/skyengine-e2e-s0opVl` 均包含完整 `P6 240x320` PPM；末帧游戏场景
关键像素正确，窗口首尾分别约有 5--6 万变化像素。历史 patch 的隔离 A/B
产物也同样持续变化。因此 failure 与旧 patch 的 pass 都不是冻结或离开
游戏场景造成的 draw-count 假象。

当前工作树的 C 源码差异仅删除本问题的临时 wrapper legacy queue/
table[31] interval 探针及其声明；目标测试恢复并加强了历史回归覆盖。
`git diff --check` 和最终 rebuild 均通过。由于尚无符合约束的实现，没有把
无意义的“兼容回归通过”作为完成证据，也没有运行整套 Optwar/DOTA/GGHJT。

### 需要产品选择的约束冲突

在现有证据下，继续实现只能选择以下两类语义之一：

1. 保持核心模拟器符合 SKY/MRC：接受 guest 在 resume 中把 repeat period
   明确改为 10ms；该 fixture 会保持约 3.4x，目标测试不会通过。
2. 明确允许兼容策略：修补该 MRP 的 resume 参数，或在 modal resume
   边界替 guest 恢复旧 repeat period。前者是应用/地址/interval 特判，
   后者会覆盖其他应用合法的 resume-time timer reconfiguration，等价于
   host 注入未请求的 `mrc_timerSetTimeEx`。

ownerless 100ms recovery 路由不是第三种正确方案：它已经被证明是 fallback
节流，而且对合法 wrapper 下载/启动队列存在 starvation 反例。若不明确
放宽“无硬编码/无兜底/遵循平台 timer 契约”中的至少一项，就不存在可以
提交的核心修复。

## 2026-08-06 用户纠正后继续实现

### 上一节“约束冲突”结论作废

用户明确纠正：本任务没有“遵循 SKY/MRC 定时器语义”这一要求。SKY/MRC
源码和反汇编只能用于解释现状及评估兼容性，不能作为拒绝实现“插件关闭后
恢复进入前游戏速度”的硬约束。因此第 673--687 行所述“必须先放宽约束才
能继续”的结论自本节起作废；ownerless 节流方案仍因会绕过真实 wrapper
queue、饿死下载/启动任务而保持否决。

### modal cadence preservation 实现

采用与应用无关的真实 wrapper 模态生命周期边界：

```text
suspend depth 0 -> >0: 保存暂停前 primary repeating timer 的 node/period
suspend depth >0 -> 0: 校验同一 node 的 magic/repeat 后，只恢复 period
```

候选来自运行时反汇编探针已发现的 primary compact scheduler offset，读取
其 queued/current head；不再误用只读 primary RW `+0x88/+0x8C` 的
`read_game_timer_head()`。代码不检查应用名、模块代码地址或具体 interval，
也不改变 host timer owner、wrapper queue 或全局 timer interval。关闭回调
写入的 `remaining(+0x08)` 保持不变，因此恢复后的即时首拍仍生效；只将
repeat walker 后续沿用的 `period(+0x04)` 恢复为模态进入前节奏。

`arm_ext_call()`、`arm_ext_call_dispatch()` 以及 primary compact walker
早返回入口均按“guest callback 前抓候选、callback 后确认 outer depth 边界”
处理，模块字段负责跨入口配对。节点消失、magic 变化或 repeat 清零时不写入，
且无论成功与否都清除本次 modal 快照，避免污染后续流程。

### 目标与兼容验证

第一次按旧 lifecycle head 抓取的实验是 no-op，窄诊断证明该 head 为零，
而真实 scheduler 动态 offset 为 `0x98`。改为 discovered scheduler head 后，
无 ARM diagnostics 连续运行目标得到：

```text
baseline=9.991 resumed=9.829 tail=9.486 PASS
baseline=9.987 resumed=9.823 tail=9.485 PASS
baseline=9.990 resumed=9.833 tail=9.987 PASS
baseline=9.992 resumed=9.839 tail=9.987 PASS（补齐 direct walker 路径后）
```

第一组保留产物 `/tmp/skyengine-e2e-qvR39S` 包含恢复窗口首帧、末段首帧和
末帧的 `P6 240x320` PPM；测试同时验证两个窗口像素持续变化、游戏场景关键
像素保持正确。独立 PPM 解析得到首帧到末帧 `76,492` 个变化像素、末段首帧
到末帧 `76,249` 个变化像素，确认不是冻结或仅恢复初期运动。

随后单 worker 执行全部相关 modal/download/return/reentry 回归：

```text
test/e2e/optwar/game-play.test.ts
test/e2e/optwar/advbar.test.ts
test/e2e/optwar/exit-plugin.test.ts
test/e2e/optwar/game-prepare.test.ts
test/e2e/dota/download-plugin.test.ts
test/e2e/gghjt/download-plugin.test.ts
test/e2e/gghjt/game-start.test.ts

Test Files  7 passed (7)
Tests      16 passed (16)
Duration   501.83s
```

全文件回归中的目标采样为 `baseline=9.989 resumed=9.846 tail=9.985`。
临时 `VMRP_ARM_EXT_MODAL_TIMER_DIAG` 代码已删除，源码中没有 ownerless、
应用/地址/interval 特判或固定 interval 节流逻辑。
