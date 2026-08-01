# optwar 取消支付卡顿 10 秒分析（已修复）

分支 `fix/optwar-stuck`，用例 `test/e2e/optwar/game-play.test.ts`（令牌界面重复进入）。

## 现象

进入 netpay 令牌支付界面后按 RIGHT_SOFT 取消，`KEY SOFTRIGHT` 命令耗时 ~10.1s
（测试断言 `<1000ms` 失败，实测 10355ms/10373ms）。期间画面冻结。

## 已定位事实（2026-07-29）

1. 卡顿不在按键 guest 回调（keyEvent press/release 均 <5ms），而在随后的
   **guest `timer()` dispatch 内部**：一次 dispatch 从 17765ms 持续到 27904ms。
2. 通过 hook_table 带时间戳日志（临时 SKYENGINE_TIMER_DIAG）抓到 10s 静默的
   直接原因：

   ```
   [TDIAG] 64825917 table[29](0x2001BC,0x0,0x28,0xF0) lr=0x236469
   [TDIAG] 64825919 table[36](0x2710,0x10090,0x23DE0C,0x0) lr=0x2366E7   <-- mr_sleep(10000)
   [TDIAG] 64835919 table[33](...) lr=0xE848D9                            <-- 10 秒后
   ```

   table[36] = `mr_sleep(r0)`，r0=0x2710=10000ms。宿主实现
   `native_sleep` (src/native_dsm_funcs.c) 直接 `usleep`，阻塞主线程 10 秒。
3. 同一 lr=0x2366E7 是 wrapper 的 mr_sleep 封装 stub（0x2366D8），整个会话
   经它调用 145 次 mr_sleep：144 次参数 0x1（timer tick 让步），取消支付
   那次为 0x2710。真正的调用者要看栈回溯（见下）。
4. sleep 调用的 r2=0x23DE0C 与 wrapper timer 调度相关（timerStart 调用中也出现
   0x23DE0C），0x23xxxx 为 wrapper 代码/数据区。

## 反汇编进展（第二轮）

- guest 调用链（栈回溯，r9=0x23DBB4）：
  `0xE834D7 → 0xE849AB → 0xE83E33`（基础 wrapper, 23KB 模块, timer tick）
  `→ 0x236245(事件分发) → 0x2362A7 → 0x236BC9(delta 调度器节点回调 blx [node+12])`
  `→ 0x22B3A3(通知函数 0x22b334) → 0x22B04D(回调 0x22b038) → mr_sleep(10000)`
- 0x236b64–0x236bd6 = wrapper delta 链表定时调度器（head delta 递减、过期节点
  回调、重新 arm，最小 10ms，clamp 0xFFFF）。
- 通知函数 0x22b334(r0)：r0==3 时经 0x235f60(1,0x20/0x21,...) 服务分发调两次
  服务，成功则回调 cb(0)，失败 cb(-1)；r0!=3 直接 cb(-1)。
  cb = [r9+0x16DC+8] = [0x23F298] = 0x22b039。
- 回调 0x22b038(result)：result==0 时置 flag byte[r9+0x258+8]=1(0x23DE14)，
  然后无条件 `mr_sleep(10000)`（0x2710 为代码字面常量）。
- 0x23F290 附近是一张回调表（0x22af01/0x22af11/0x22aed9/0x22af31/0x22b405/
  0x22b425/0x255b8c/0x22b039/0x22af71）。
- 之前观察到的 2 秒无 table 调用间隙 = 支付场景下 wrapper timer 停止的正常
  空闲（等按键），非卡顿。取消卡顿的全部时长 ≈ mr_sleep(10000)。
- 宿主 mr_sleep = native_sleep = usleep，阻塞 SDL 主线程；真机上 mr_sleep 也
  阻塞 VM 线程，guest 在 sleep 期间无法观察到任何事件——sleep 的 guest 可见
  效果只有"时钟前进"。
- dump 文件：/tmp/wrapper_dump_0x220000.bin(256KB)、_0x2B0000.bin(128KB)、
  _0xE80000.bin(64KB)；反汇编 /tmp/wrapper_dump.asm（thumb, vma=0x220000）。

## 修复方案（已原型验证）

真机上 mr_sleep 阻塞整个 VM 线程，sleep 期间 guest 收不到任何事件，唯一可
观察效果是返回后 mr_getTime 前进了 ms。因此宿主无需真睡：把
`native_sleep` 改为回拨 `native_uptime_base`（guest 虚拟时钟快进），guest
语义完全一致，SDL 主线程不再冻结。改动仅 src/native_dsm_funcs.c 一处，
无应用识别、无阈值兜底。

验证：
- 驱动脚本取消支付 KEY 耗时 10126ms → 125ms；
- 取消后 PPM 像素 (222,287)=(48,188,248)、(230,20)=(168,20,32) 正确；
- `pnpm vitest run test/e2e/optwar/game-play.test.ts` 通过（21.3s，
  修复前 28.4s 且断言失败）。

## 模块归属结论（子 Agent 分析）

- 0x220000-0x260000 为 guest 堆（EXT_HEAP_ADDR 起的 LG_mem）；其中
  0x2263A0-0x23DBAC = **optwar.mrp:game.ext**（解压 96268B 平铺映射），
  r9=0x23DBB4 = 映像末尾+8（ZI/RW 区）。
- `mr_sleep(10000)` 调用（0x22B038）= game.ext 文件偏移 0x4C98——是**游戏
  自身代码**，不是 netpay 插件代码。
- 0xE80000 = optwar.mrp:cfunction.ext（23492B，基础 wrapper，EXT_CODE_ADDR）。
- 0x2B0000 区 = wrapper 模块/定时器管理堆（compact timer 节点 magic
  0x79ABBCCF；各 ext 映像头 8 字节被加载器改写为指向 0x2Bxxxx 的控制节点对）。
- 回调表 0x23F290（含 0x22B039）在 game.ext 映像之外的 ZI 区，是**运行时
  注册**的（值依赖 first-fit 动态基址，文件中无预重定位形式）。
  即：netpay 取消路径通过游戏注册的支付结果回调进入游戏自己的
  sleep(10000) 代码。

## sleep(10000) 语义结论（子 Agent 反汇编）

- 0x22B038 是 freecurr（令牌插件）结果回调的收尾：result==0 时置成功标志
  byte[0x23DE14]=1，随后**无条件** `mr_sleep(0x2710)`——0x2710 是代码字面
  常量（0x22B054），不是调度计算值。
- 设计意图：插件发出"请平台加载/重启 plugins/freecurr.ext"（service
  0x20/0x21）后主动睡 10 秒，把 VM 线程让给平台完成 stop→start 接管。真机
  上 mr_sleep 同样阻塞 VM，但平台会在窗口内完成切换，用户看到的是应用切换
  而非冻结。
- 取消路径实测走的是生命周期事件码 4（param=4 的 50ms 通知节点 0x255B8C），
  通知函数 0x22B334 对 param!=3 直接以 result=-1 调回调——不发加载请求、
  只睡 10 秒。即这 10 秒在取消路径上本来就"什么都不等"，纯粹是插件代码的
  兜底冷却。
- 因此宿主侧正确语义是"时间流逝对 guest 可见"而非"宿主陪睡"：虚拟时钟
  快进完全保留 guest 可观察行为（mr_getTime 前进 ms），且不冻结主线程。
  修复与事件码 3/4 的映射无关，对成功支付路径同样成立（成功路径的 sleep
  同样只等时间流逝，平台接管由宿主 wrapper 生命周期逻辑另行处理）。

## 回归

- `pnpm vitest run test/e2e`（retry=0）：34 文件 / 57 用例全部通过（干净
  环境两轮全过）。
- optwar 用例连跑 4 次全部通过（~21s/次）。
- 注意事项：中间两轮出现过成批 "E2E socket was not ready" 失败，均为环境
  残留（一个卡死的 skyengine 进程 + /tmp 下数百个 skyengine-* 残留目录）
  导致的启动超时，与本修复无关；清理后全过。跑全量前建议确认无残留
  skyengine 进程。

## 待办

（无——修复已落地并回归。若后续要做"支付成功后平台接管"保真度，可从
事件码 3/4 的生命周期映射入手，见语义结论一节。）

## 复现工具

- 复现步骤已固化在 test/e2e/optwar/game-play.test.ts（三次取消支付各断言
  <1000ms）。排障期间的临时驱动脚本与 TDIAG 日志代码均已移除。
- dump 文件（/tmp，临时）：wrapper_dump_0x220000.bin / _0x2B0000.bin /
  _0xE80000.bin；反汇编 /tmp/wrapper_dump.asm。
