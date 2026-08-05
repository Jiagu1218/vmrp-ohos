# optwar advbar 浏览器返回后游戏卡死分析

## 问题

`pnpm vitest run test/e2e/optwar/advbar.test.ts` 执行后卡死。

- 预期：广告(浏览器插件)返回后，游戏界面(full-power 支付页)恢复可操作。
- 实际：浏览器菜单选「返回」回车后，屏幕停在顶部广告条 + 黑屏「请稍等...」
  (full-power-2.ppm 黑屏占 87%)，等待 10s 超时,像素断言失败。

## 已知事实(2026-08-04)

- 分支 fix/optwar-too-fast,基线 4b3a2c9(含 reset_child_modules(closed_p) 修复
  与 main.c timer generation 校验)。
- 复现 2/2:测试在 `full-power-2` 断言点失败(~50s 结束,exit 1),不是进程 hang。
- 卡死画面 = wrapper 的加载屏("请稍等...")+ advbar 广告条仍在顶部。
  → 浏览器子模块已关闭,wrapper 正在恢复/重载 game,但恢复流程停滞。
- stdout 末段:brw 浏览器 POST /page2 → 返回操作 → my_socket(s:9) 创建后
  立即 closeSocket(s:8)/(s:9),此后再无任何输出;无 invalid memory、无崩溃。
- 流程与 gghjt 的 netpay 下载/返回同构(dump0 恢复),相关历史修复见
  docs/optwar-ad-click-fetch-unmapped.md、memory optwar-resume-speedup-mutex-issue。

## DIAG 运行结论(artifact /tmp/skyengine-e2e-yWfgH1, 17834 行)

时间线(行号为 stdout.log):
- 3334: code=1 进入模态(购买火力全开 → netpay 支付页, activeP=0x2E6B54)。
- 4121: 第一次模态关闭(1→0, code=2, 下载流程中段), 4195: 立即重开(0→1)。
- 4216-4236: wrapper 把 game 内存 614400 字节(0x226380..0x2BC380)写入
  plugins/dump0(table40 flags=0xA + table43 x N)——浏览器启动前的挂起快照。
- 浏览器阶段 activeP 依次为 netpay 子模块/brwgui/brwshell(0x2E825C),
  modalDepth 恒为 1。
- 15560-15611: 「返回」触发的最终关闭(code=2):
  1. wrapper 画全屏"请稍等"(present29 240x320, lr=0xE844A5);
  2. table44 把 dump0 读回 0x226380(codeOverlap=0x2263A0..0x23DBAC,
     即 game.ext 映像被恢复);
  3. stale_child_drop 丢弃全部 9 个子模块记录(smsend/advbar/netpay 子
     模块/brwgui/brwshell), restore_primary_mapping_after_dump0 重登 primary;
  4. table131 cmd=9 (mr_cacheSync) data=0x226380 len=614400, internalLoader=0;
  5. wrapper 重挂 timer(t=46/t=10), advbar 残留节点画了一次顶部广告条
     (present29 240x40, lr=0x24952D r9=0x24EC8C);
  6. suspend 1→0, 宿主关闭清理执行(active→primary, reset_child_modules,
     modal 屏幕快照恢复——快照内容是"请稍等"画面,因为模态中途 4121→4195
     的 depth=0 窗口重存过快照)。
- 15613 之后(稳态死循环, 持续到测试超时):
  - 每个 code=2 都路由给 wrapper(timerP=0x325E5C timerH=0xE800B0 恒为
    wrapper, `timer_owner lr=0xE848FE` 每 tick 重记 owner=wrapper);
  - wrapper 每 tick 调 2 次 table31(t≈6-7ms 与 t=10ms), 队列(wrw+3C8=
    0x2BCB30, +3CC=0x2BCF08, 即 smsend/advbar 的 extChunk 定时器节点,
    P-0x24)永远 live;
  - `game_timer_head_zero grw=0x23DBB4` 每 tick 出现(game timer head
    恒 0, 全程 618 次, 从未有非零 pre 值——optwar 不用该机制,
    primaryTimer=1 来自 compact 队列判定);
  - **无任何 present29**(游戏再也没画过一笔), 无 table40/44 文件读,
    无 code=1 分发——guest 只在 wrapper 的 6-10ms 定时器空转。

## 结构判断

与 81aae96(origin/master「突然加速」修复)处理的是同一结构: 模态关闭后
wrapper 残留 timer owner, tick 永远进 wrapper 而饿死 primary。但本用例内
有两次关闭, 判据完全同值(code=2 + foreground_child_active=1 +
wrapperLive=1 + primaryLive=1 + owner=wrapper):
- 关闭#1(4121, 下载确认): wrapper 必须保留 owner 继续推进下载队列
  (释放 owner 会 hang 在 download/启动——memory 中 A/B 尝试的失败模式);
- 关闭#2(15611, 浏览器返回): 必须释放 owner 让 game 恢复。

**新判别信号**: 关闭#2 在同一回调内发生了 dump0 primary 映像恢复
(arm_ext_restore_primary_mapping_after_dump0 触发), 关闭#1 没有。
"wrapper 在本回调中把 primary 的内存映像整体读回"是 wrapper 自己的
挂起/恢复协议步骤, 不含应用指纹。

## 实验记录(2026-08-04)

1. **81aae96 整包实验**: 把 origin/master 的「突然加速」修复(释放关闭时
   残留的 wrapper timer owner, 判据 code=2+childActive+wrapperLive+
   primaryLive)打到当前树 → advbar 测试在**更早**的下载/启动阶段
   `wait_draw_timeout`(20s)——证实互斥: 下载模态关闭点释放 owner 会
   饿死 wrapper 的安装/启动队列。已回滚。
2. **延迟恢复实验**(advbar-diag.test.ts, 返回后逐秒采样 60s):
   pixel(213,151) 60s+ 恒黑 → **永久卡死**, 排除"wrapper 队列 due 被
   mr_sleep 虚拟时钟推远、迟到恢复"假设。
3. code=2 路由确认(arm_ext_executor.c:1805-1815): timer owner 为空时,
   code=2 默认路由到 **primary helper**——释放 owner 即可让下一拍进入
   game 恢复重绘。

## 修复(v1, 待回归)

判别信号: `arm_ext_restore_primary_mapping_after_dump0`(table[44] 大块
读回完整覆盖 primary 映像 = wrapper 挂起快照恢复协议)在本次回调内触发。

- arm_ext_internal.h: 新增 `primary_dump_restored_in_call`。
- aex_module.c restore_primary_mapping_after_dump0: 置位。
- arm_ext_executor.c arm_ext_call: 入口清零;模态关闭边界
  (suspend>0→0)若 `code==2 && foreground_child_active && 该标志 &&
  owner==wrapper` → 释放 timer owner。
- 子模块流程中段关闭(取消下载等)无 dump0 恢复, 不满足标志, owner 保持
  ——与 81aae96 的互斥点正是靠该标志解开。

## 修复 v1 复测(仍失败)与 v2

v1 复测: owner 释放已生效(关闭后 timerP=0x0), **第一拍确实进入 game
代码**(callP=primary, call-post lr=0x22AED1 r9=0x23DBB4)。但该拍内
guest 停了 timer(hostTimer=0 mrTimer=0), 宿主的 reopen 补启逻辑
(`primary_child_reopen_timer_needed && !host_timer_pending &&
mr_timer_state==0`)无条件把 owner 重新标回 wrapper → 下一拍起又回到
wrapper 空转。与 81aae96 发现的第二半问题一致。

v2: 移植 81aae96 的 `primary_resume_without_timer_owner` 机制, 但置位
条件改为本修复的 dump0 判别——释放 owner 时置位; reopen 补启拍若该标志
有效且 active==primary, 保持无 owner; 新模态进入或 dispatch 路径关闭时
清零。

## v2 复测(仍失败)与新的反汇编证据

v2 复测: 每拍都进 primary helper, 但 game 的 code=2 每拍只做 3 次
table[33](getTime, lr=0x236B0F/0x236AD5/0xE84805)就返回——**game 自己的
delta 调度器(head=grw+0x8C)是空的**。game 的定时任务按真机架构经
mrc_extTimerStart 全部挂在 wrapper 队列(节点 P-0x24), 只有 wrapper 的
code=2 walker 能分发; 单纯把 tick 路由给 primary 无法唤醒游戏。v2 反而
饿死了 wrapper 队列。

TRACE 全量 table 日志新证据:
- 浏览器启动时 game 挂了 60s 看门狗: `table[31](0xEA60=60000)`,
  wrapper 后续以剩余值重挂(0xEA14→0xE796→...); 关闭时刻 wrapper 队列
  game 节点 [0x0C]=0x8EF4=36596ms 即其剩余。
- 本用例全程无 mr_sleep(10000)(table[36] 全部是 1ms 让步), 排除
  mr_sleep 虚拟时钟欠账假设。
- 延迟观察实验 63s 仍黑屏 → 60s 看门狗到期路径也没有生效。

wrapper 反汇编(cfunction.ext, /tmp/optwar-wrapper-analysis/):
- 0xE847C4 = 定时器节点插入函数: node[0x08]=magic 0x79ABBCCF,
  node[0x0C]=时间源()+interval(绝对 due, 按 due 排序插入),
  node[0x10]=interval; 时间源 = blx [ctrl+0x84]。
- **插入函数开头检查 [[0xE7FFC8+0x38]+0x5C][8][0](wrapper 控制状态),
  为 3 或 4 时直接丢弃插入**——若浏览器返回后该状态残留 3/4, game 恢复
  时重挂的所有定时器都被静默丢弃, 与观察一致。
- 0xE7FFC8 = wrapper PIC 全局基址(寄存器转储中的 r4), ctrl=[0xE80000]。
- 已加 TEMP-DIAG(wrapper_state)逐 tick 打印该状态链, 验证中。

## 反汇编定案(子 Agent, 全文见 /tmp/optwar-wrapper-analysis/FINDINGS.md)

- 状态门探针实测 state=1(RUN), wrapper 层状态门不是卡点。
- **唤醒协议**: wrapper 恢复(0xE80FBC→0xE83DAC)对每个 child:
  record[0x34]-- 归零时重挂外层节点 + `blx record[8](record[0x1C],5,0,0)`
  ——**code=5 事件是唯一唤醒调用**。game 的 code=5 处理器
  (0x236245→0x236488→0x229D9C)在 `[grw+0x320]!=0` 时经 0x236998 重挂
  内部 10ms 帧定时器(cb≈0x22AE55, repeat=1), 置 grw[0x277]=1 全量重绘。
- wrapper 外层机制在模拟器内完全正常: game 外层节点每拍到期、蹦床
  0xE83E1C 每拍把 code=2 打进 game; due/now 同源(table[33])。
  **卡点 = game 内层调度器(grw+0x98, head 存 grw+0xA0)从未被重新装载**
  ——code=5 已投递但 0x229D9C 里的重挂未生效。
- 四候选: A) [grw+0x320]==0; B) 对象 magic 被覆写; C) game 子表
  ([0x2263A0]+0x5C)状态门≠RUN 静默丢弃; D) code=5 投递 r0/r9 保真。
- v1/v2(释放 timer owner)已回滚——实验+反汇编共同证明方向错误:
  game 缺的不是 tick, 是 code=5 重挂成功一次。
- 新 TEMP-DIAG(game_gate/game_sched)裁决四候选, 运行中。

## 根因定案(2026-08-04 晚)

四候选探针全部排除(fto=0x23FEEC 非零、magic 完好、state=RUN), 且
game 内部帧节点(head=0x23FEEC delta=0 cb=0x22AE55 recur=1)一直挂在
自己的调度器里。WATCH_PC 监视(0x229D9C/0x22AE55/0x236B00/0x236BC6)
给出决定性证据:

- 正常阶段: 分发点 0x236BC6 与帧回调 0x22AE54 入口 r9=0x23DBB4(正确);
- 卡死阶段: 同两点 r9=0x225E60(wrapper RW)——**帧回调每拍都在被调用,
  但带着 wrapper 的 R9 运行**, 所有 R9 相对的游戏状态读取都读到
  wrapper 数据, 于是静默不画。
- R9 纠正计数器: 卡死期间 block hook 照常(+169/拍), 但 fixPrimary
  冻结(2306 不增), fixWrapper 每拍+1——宿主的逐 block R9 纠正对 game
  代码完全失效, 而 wrapper 段入口的强制改写还在(污染源)。
- nested_mods 探针: primary 记录在场且正确(file=0x2263A0/96268,
  rw=0x23DBB4)——不是记录丢失。

**真凶 = pending_internal_file 毒化**: `aex_t131`(mr_cacheSync, cmd=9)
无条件把同步范围设为 `pending_internal_file_addr/len`。浏览器返回的
恢复拍, 该范围是整个 dump0 恢复区 0x226380..0x2BC380, **完整罩住
game 映像**; 而 `arm_ext_find_nested_module` 的"pending staging 窗口"
规则会跳过与 pending 重叠的记录(为私有 loader 子模块 staging 设计)。
整块恢复永远不会出现描述它的 extChunk, pending 永不清除 → game PC
的归属查询永远 NULL → R9 纠正永久失效 → 桥调用(timerStart/Stop
veneer)的 R9 污染成为永久态。

## 修复(v3, 最终)

`src/arm_ext/aex_table.c` aex_t131 cmd=9: 若同步范围**完整包含
primary 映像**(= wrapper 的挂起快照/arena 整块恢复协议, 非子模块
staging), 不设 pending_internal_file、不做子模块登记, 只保留
uc_ctl_remove_cache(TB 失效必须); 并清掉残留 pending。
v1/v2(timer owner 释放)已全部回滚, 无新增字段。

## v3 复测: R9 修复生效但仍未通过

- WATCH_PC 复测: 稳态分发点/帧回调 r9=0x23DBB4(正确), fixPrimary
  计数恢复增长——R9 纠正已修复 ✓。
- 但 full-power-2 仍黑屏"请稍等"(这次无广告条)。
- 深层原因(下一层): 帧回调以正确 R9 每拍运行, [grw+0x320] 帧节点已
  重挂, suspend=0, 但 game 高层状态在等"子包退出/支付结果"事件——
  按反汇编该事件由 wrapper 返回处理器末尾的事件重放总线
  (0xE81080/0xE8168C, wrw+0x3C 链表)投递; 稳态里 game 内部队列只有
  帧节点、没有通知节点(0x255B8C 类), 说明重放事件未到位或 game 的
  事件处理器没安排后续。
- 已再次委派反汇编子 Agent 深挖事件重放链; 并行实验: 卡死态注入按键
  能否唤醒。

## 事件总线取证(v3 之上)

- 卡死态注入 ENTER/DOWN/LEFT_SOFT 均无反应(40s 双色黑屏,
  colors=2)——输入不能唤醒。
- 事件重放链表头 = [wrw+0xC4](0xE81080: [r9+0x88+0x3C], 字面量 0x88)。
- 探针结果: 关闭拍队列中有 2 个事件(code 0x20 与 0xE), 重放已消费;
  **卡死期(970 拍)恒挂着 1 个之后新入队的事件 node=0x2E67E0,
  [8]=0x1 [12]=0x2C(code 44?), 永不投递**。恢复拍无任何宿主
  clean-exit 中断——guest 正常跑完, 问题是总线判定"暂不可投递"入队后,
  再无一次重放来消费它。0xE8168C 的 deliver-or-queue 判据待反汇编
  子 Agent 定论。

## 第二真凶定案(反汇编子 Agent 第二轮, TRACE 实证)

恢复拍序列: dump0 整读 ✓ → **stale_child_drop×9 丢弃全部 child 记录,
包括 dump 里逐字节复活的 smsend@0x23FF10 与 advbar@0x241F40** →
resume ✓ → 帧定时器重挂 ✓ → 0xE81080 开始重放 deferred 事件
(0x2E67E0{id=1, code=0x2C, a=0x24741D∈advbar}) → 0xE84474
blx [wrw+0x344](advbar 注册的事件前置钩子, dump 恢复原值) →
**advbar 无登记 → R9 纠正不覆盖 → 以 wrapper R9 执行读垃圾 →
blx 0x1C201C28 → FETCH_UNMAPPED → uc_emu_start 整拍中止**。
重放没跑完、支付结果邮箱(wrw+0x280 块)20ms 交付节点没挂、game 的
50ms 重开节点(0x255B8C→0x22B334→服务 0x20 重开支付插件)没机会。

帧回调之门 = grw[0x275](插件模态标志): 非零时 0x22AE54 跳过
0x2275CC(游戏逻辑+整屏绘制), 只做输入泵——"每拍都跑却永远请稍等"
的机制; 清它的责任在被掐断的支付结果链路。

## 修复(v4)

dump0 恢复的两个记录清理点(aex_module.c
arm_ext_drop_overlapping_stale_nested_modules 与
arm_ext_restore_primary_mapping_after_dump0)改为: 与读入范围重叠的
非 primary 记录**先用 arm_ext_has_internal_loader_chunk 验活**
(恢复字节已就位: extChunk 存活 + 映像头 record/P 补丁完好 = 记录
描述的就是当前可执行内容), 验活通过保留(复活模块), 失败照旧清除
(浏览器会话期间新建、被恢复字节覆盖的 brwshell 等)。与 v3(cmd=9
整块恢复不设 pending_internal_file)共同构成完整修复。

## 结果(2026-08-04)

- **advbar.test.ts 通过**。PPM 验证: full-power-2 = 完整支付页
  (火力全开+广告条), pay-method-1 = DOWN+LEFT_SOFT 打开支付方式选择
  ——返回后界面可正常操作。
- TEMP 探针与临时测试(advbar-diag.test.ts)已全部移除, 最终改动仅:
  - src/arm_ext/aex_table.c: aex_t131 cmd=9 整块恢复不按子模块
    staging 语义设 pending_internal_file(+清残留);
  - src/arm_ext/aex_module.c: dump0 恢复两处记录清理点先验活
    (has_internal_loader_chunk)再清除。
- 完整因果链(两个互相叠加的宿主 bug):
  1. pending_internal_file 毒化 → game 代码失去 R9 归属 → 帧回调以
     wrapper R9 空转;
  2. stale_child_drop 丢弃 dump 复活模块记录 → 事件重放 blx advbar
     钩子时 R9 未纠正 → FETCH_UNMAPPED 整拍中止 → 支付结果邮箱/
     game 重开节点被掐断 → grw[0x275] 模态标志永不清除。
