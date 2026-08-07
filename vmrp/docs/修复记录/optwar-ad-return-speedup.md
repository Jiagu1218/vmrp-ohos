# optwar 从广告/支付返回游戏后突然加速 分析记录

## 问题

`pnpm vitest run test/e2e/optwar/game-play.test.ts -t 突然加速1`：
返回游戏界面后游戏持续约 4 倍速（基线 ~10 draws/s，返回后 ~40.7 draws/s）。

## 背景

- 分支 analysize（含 v3/v4 “从广告返回卡死”修复 f619149）。
- master 的 81aae96 “突然加速”修复（模态关闭边界释放 wrapper timer owner +
  `primary_resume_without_timer_owner`）在本分支已被实验证明与 advbar
  下载确认流程互斥（释放 owner 会饿死 wrapper 安装/启动队列），未合入。
- 本分支现有 `突然加速1` 用例（无进广告步骤）即可直接复现失败。

## 取证（2026-08-04, TEMP-DIAG, artifact /tmp/skyengine-e2e-768cQ0）

TEMP 探针（SKYENGINE_ARM_EXT_TIMER_OWNER_DIAG 门控，修复后删除）：
- `aex_t031`: 每次 guest timerStart 的间隔+LR；
- `arm_ext_call` code=2 结束: 转储 wrapper legacy 定时器队列
  (wrw+0x3C8/+0x3D8, 节点 due@0x0C interval@0x10 cb@0x14)。

结果：
- 全部 1503 次 timerStart 都经 wrapper veneer LR=0xE848FE（结构不变）。
- 正常阶段：game 外层节点 node=0x2BC758 data=0x2BC71C cb=0xE83E1D(蹦床)
  **interval=100**；每拍 t31 组合 `100 + ~84..91`（下次到期 delta）。
- 支付模态期间：game 节点不分发（dueDelta -70..-82 越欠越多），每拍
  t31 组合 `100 + 10`。
- 关闭一拍：t31 序列 `1, 1000, 10, 10`；此后队列 =
  `[0x2BCB30 interval=0 cb=0(清零节点), 0x2BC758 interval=10(!), 0x2BCF08 interval=1000(advbar)]`。
- 稳态：game 节点 **interval=10 永久保持**，每拍 due+=10 重插 →
  宿主 10ms tick → 游戏 4×速。

## 结构判断

加速不是宿主 timer owner 路由错误（正常期 owner 也是 wrapper，架构即
如此：game 定时任务挂 wrapper 队列，由 wrapper walker 按 due 分发）。
根因是**恢复拍 guest 把 game 外层节点从 100ms 重挂为 10ms 循环节点，
且从未切回 100ms**。10ms 应为恢复快拍（与 advbar 卡死分析中 code=5
resume 重挂"内部 10ms 帧定时器 cb≈0x22AE55 repeat=1"一致），真机上游戏
稳定后应回到 100ms 节奏。

待反汇编解答：
1. game.ext 里 10ms 与 100ms 两种重挂的调用点与选择条件；
2. 恢复后什么状态/事件让游戏把节奏切回 100ms，模拟器里为何缺失。

## game.ext 反汇编定案（子 Agent + 人工核验关键指令）

校准：文件偏移 = VA − 0x2263A0；产物 /tmp/optwar-speedup-analysis/。

- game 内部 delta 调度器：节点 `[4]=interval [8]=剩余delta [0xC]=cb
  [0x10]=data [0x14]=repeat [0x18]=next`，magic 0x79ABBCCF，head 在
  grw+0xA0。编程函数 `0x236998(node, interval, data, cb, repeat@[sp])`：
  interval 下限钳 10ms；r1==0 保留旧 interval；开头 0x2369C2 有
  `[[ctrl+0x5C]+8][0]∈{3,4}` 的 wrapper 状态门（静默丢弃插入）。
- 外层编程 0x236AC4：getTime → timerStop → table[31]（game.ext 唯一
  timerStart 调用点，经 wrapper veneer 0xE848FC，故 lr=0xE848FE）。
- walker 0x236B00（code=2 唯一入口）：外层间隔=max(最早delta−迟到,10)；
  repeat 节点以 r1=0 重插 → **永远沿用 node[4]**。
- **100ms 唯一来源 = 0x22AD7C 应用初始化**（0x22AE1C `movs r1,#0x64`，
  repeat=1，句柄存 grw+0x320），仅 code=0 启动时执行一次（已核验字节）。
- **10ms 来源 = code=5 resume 处理器 0x229D9C**（0x229DB2 `movs r1,#0xa`，
  repeat=1，同一节点同一 cb 0x22AE55；已核验字节）。链路
  code5→0x236488→0x235724→0x229D9C 无条件。
- game.ext 全部 6 个 0x236998 调用点核对完毕：无任何"切回 100ms"路径。
  帧回调 0x22AE54/游戏逻辑 0x2275CC 均不重编程定时器。
- game 逻辑按 tick 计数驱动（0x229DE4 每拍+1），非墙钟驱动 →
  游戏速度 = code=2 投递频率。

## SKY 平台真机语义（子 Agent, third_party 源码）

- mr_timer 单实例、one-shot、无 clamp，到期在 MMI 任务直调 mr_timer()
  （MTK mrp_core.c:433-452 / SPRD mmimrapp_wintab.c:2621）。
- pause/resume 平台层不记剩余时间；VM resume 固定 MR_TIME_START(300) 一拍。
- 10ms 在真机 ≈ 2-3 个 KAL tick，合法。

## 当前决定性疑点（wrapper 状态门时序）

game 的 0x236998 开头有 wrapper 控制状态门：state∈{3,4} 时**静默丢弃**
插入。若真机上 wrapper resume 投递 code=5 时状态仍是 3/4（先通知子模块、
后置 RUN），则 10ms 重编程在真机被丢弃、节点保持 100ms —— 加速就是模拟
器的状态时序错误而非原生行为；若 resume 先置 RUN 再投递 code=5，则加速
为原生行为（真机仅靠硬件慢掩盖）。已派子 Agent 反汇编 cfunction.ext 的
suspend(0xE831A4)/resume(0xE80FBC→0xE83DAC) 状态机裁决。

另：master 81aae96 之所以恢复 100ms，是 owner 清空后 wrapper resume
重放被跳过 → code=5 未投递 → 节点保持 100 —— 副作用修复，非根因。
