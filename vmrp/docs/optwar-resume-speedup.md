# optwar “返回游戏界面后突然加速” 分析记录

## 症状
测试 `test/e2e/optwar/game-play.test.ts -t 突然加速`:
进入游戏 → 菜单 → 购买火力全开 → 支付方式 → 令牌支付 → 取消 → 返回菜单 → 返回游戏界面后,游戏持续倍速运行。

## 基线数据 (2026-07-30, 无修改代码)
- 正常游戏场景: `SPEED-DIAG normal-draws 20` (2s 内 20 帧 = 10 fps)
- 返回游戏后: 250ms/8帧, 750ms/24帧, 2000ms/58帧, 7000ms/197帧 ≈ **28~32 fps,持续不衰减**
- 结论: 是持续 ~3× 倍速,不是瞬时追帧。

## 已否决的方案
- `src/main.c timerStart()` 里 clamp 最小间隔到 50ms(d0a37f1 之前的工作区改动):
  属于兜底/硬编码风格,已还原。且它只是掩盖 wrapper 请求了过小 timer 间隔的事实。

## 2026-07-31 定时器取证

- 保留产物: `/tmp/skyengine-e2e-8gYQL7`。
- 正常游戏阶段由约 `100ms` 的游戏 tick 驱动。进入/退出支付流程后，从
  SDL tick `17115` 起宿主被连续重启为 `10ms`，到用例结束的 `27581`
  仍未恢复；这与返回后约 3 倍绘制速率同窗出现。
- `10ms` 不是 `timerStart()` 自行截断产生的值，而是 guest 每次回调后重新
  调用 table[31] 传入的值。因此在宿主 timer 层 clamp 会掩盖错误所有权，
  不能作为修复。
- 历史 `8ac50f8^` 的通用模态关闭路径曾在前台 child 关闭且 timer owner
  仍是 wrapper 时清空 `timer_p_addr/timer_helper_addr`；注释明确说明不清理
  会让 wrapper cleanup 被反复重放并饿死 primary code=2。`8ac50f8` 重构
  删除了这段归属转移，而当前路径仍会设置
  `primary_child_reopen_timer_needed=1`，使 `arm_ext_primary_helper()` 继续绕过
  primary 直达路径。两项证据共同指向“关闭后的 wrapper timer owner 残留”。
- `SKYENGINE_ARM_EXT_TIMER_OWNER_DIAG` 进一步确认，成功复现中的 1049 次
  `timerStart` 全部来自 `LR=0xE848FE`，owner 均为 wrapper
  `P=0x325E5C/H=0xE800B0`。关闭边界是 wrapper helper code=2 将 suspend
  depth 从 1 降为 0，并在同一拍重挂 `1000 -> 10 -> 10ms` timer。
- 回归对照补足了结构判据：DOTA 的合法关闭是 `code=1, wrapperLive=1`；
  GGHJT 的合法 timer 关闭是 `code=2, wrapperLive=0`；只有 optwar 同时满足
  `code=2, wrapperLive=1`。因此不能只按 callback code 或 owner 地址转移。

## 根因与修复

- child 关闭后，wrapper 已失去前台调度权，但它在 resume 中重挂的 timer
  仍被记录为宿主 timer owner。后续 code=2 因此持续进入 wrapper cleanup，
  primary 的正常游戏 timer 无法重新取得驱动权。
- 在 `arm_ext_call()` 的 suspend depth `>0 -> 0` 边界，只有本次是 timer
  callback (`code=2`)、确有前台 child、关闭瞬间 wrapper queue 仍 live，且
  timer owner 仍为 wrapper 时才清空 stale owner。queue 必须在恢复 wrapper
  前台快照之前采样，否则快照恢复会覆盖判据。不能把该转移套到
  `arm_ext_call_dispatch()`：后者仍需 wrapper owner 推进下载/重进队列。
- `primary_resume_without_timer_owner` 持久记录本次精确匹配的关闭。后续补启
  timer 时，只要 active 已回 primary 就继续保持无 owner，使现有路由进入
  primary 的公开 helper 完成恢复；新模态进入后清除该标志。不能显式标成
  primary owner，否则会绕过公开 helper、直接进入 compact walker，实测四拍
  后画面冻结。事件关闭、空 wrapper queue 或已加载新 child 均保留 wrapper
  owner，以继续推进 resume/reopen 队列。
- 修复不依赖应用名或 timer interval clamp。

## 验证

- 诊断产物 `/tmp/skyengine-e2e-HCdDKk`：正常阶段 `20/2s`；返回后各窗口为
  `2/250ms`、`6/750ms`、`18/2s`、`61/7s`，稳定窗口约 `8.7 draws/s`。
  关闭边界后 timer 序列持续为 `100ms`，不再持续请求 `10ms`。
- `game-play.test.ts` 现以实际墙钟时间归一化，要求返回后的 7 秒稳定窗口及
  最后 2 秒子窗口都在支付前基线的 `0.5x..1.5x` 内；最后 2 秒的首尾 PPM
  必须变化，末帧还需保持在游戏场景，从而覆盖“持续倍速”“后半段冻结”和
  “测量期间离开游戏场景”三类回归。
- 最终兼容验证：Optwar 的 `game-play`、`game-prepare`、`exit-plugin` 共
  3 个文件 6 个用例，DOTA 下载插件 2 个用例，以及 GGHJT 的 5 个
  下载/返回/重进用例均通过。GXDZC 使用同一自动点击序列运行到付费取消后
  保持存活且无 runtime error；仓库中的旧脚本路径 `mythroad/gxdzc.mrp`
  不存在，验证改用同内容的 `test/fixtures/gxdzc.mrp`。
