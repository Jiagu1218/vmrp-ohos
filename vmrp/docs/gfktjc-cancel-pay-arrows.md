# gfktjc 取消支付后训练页出现左右箭头（emulator-specific，真机无）

用例：`pnpm vitest run test/e2e/gfktjc/render.test.ts -t 游戏内`
断言失败点：训练选择页取消计费返回后，像素 (227,153)=rgb(248,156,0)、(10,155)=rgb(248,168,0)
出现左右箭头（frame_bigarrow.bmp），真机不出现。

## 复现流程（test 已固化）
main → RIGHT_SOFT(不加速) → RIGHT_SOFT(不开音乐)+ENTER → ENTER(开始) → ENTER(存档)
→ ENTER(选任务job) → ENTER(训练选择) → ENTER(进付费蓝屏) → RIGHT_SOFT(取消) → 返回训练页

## 现象刻画（已定论）
- 初始训练选择页：无箭头，持续 3s+。LEFT/RIGHT 导航无效（内容 fp 不变）。
- 取消返回后：箭头在 ~0.47s 出现并持续 ≥6s。LEFT/RIGHT 仍无效，内容 fp 不变。
- 即箭头是"返回路径特有的伪绘制"，非功能性轮播指示。

## 渲染架构（已定论）
- 游戏把整屏 240x320 合成到 guest 0x2001BC 离屏缓冲，再经 host c_function table[29]
  (aex_t029) 整屏上屏；present 调用点 guest lr=0x247C71 (game+0x21988)，每帧一次。
- 0x2001BC 缓冲为 host-mapped(uc_mem_map_ptr)：guest 写不触发 UC_HOOK_MEM_WRITE，
  个别像素/中心像素 write-watch 全 0。故箭头绘制点无法用 write-watch 直接抓。
- 箭头位图 frame_bigarrow.bmp / frame_smallarrow.bmp 由包内偏移读取(非独立 mr_open)，
  按资源名表 INDEX 引用；名表记录在 game dump file-off 0x38a90(bigarrow)/0x38ed8(smallarrow)。

## 关键调试设施（临时，收尾前全部移除）
- src/arm_ext/aex_diag.c: `SKYENGINE_ARM_EXT_DUMP=1` → 每个注册模块 dump 到 /tmp/mod_<base>.bin。
  已 dump：游戏 /tmp/mod_2262E8.bin(base 0x2262E8,len 0x422D8)；netpay 0x26D9E0；wrapper 0xE80000。
- src/arm_ext/aex_table.c t029: `SKYENGINE_RAMDUMP_DIR` + 触发文件 GO → 稀疏 dump guest RAM
  [0x40000,0x900000)；`SKYENGINE_POKE="addr:size:hexval,..."` 每帧强制写 guest RAM（因果验证）。
- src/arm_ext/aex_table.c t040: `SKYENGINE_ARROW_TRACE` → 记录文件打开。
- 现有 aex_diag.c WATCH_PC/WATCH_WRITE 设施（temp 提交）。
- 复现驱动脚本：$CLAUDE_JOB_DIR/tmp/driver2.py（跑到取消并时序采样）、driver_ram2.py（tight pre/post RAM 快照）。

## RAM 取证结论
- 用 3 快照噪声掩蔽（两 arrow 帧做 per-frame 噪声掩码 vs 一 pre 帧）得到极少候选，
  但均被证伪或为调度器伪影：
  - 0x226060 = wrapper compact-timer 调度器 current-node 指针（host-mapped，write-watch 全 0）。
    poke 回 pre 值可去箭头，但 base1(初始无箭头)该值 == arrow 值，故非门控本源（红鲱鱼）。
  - 0x327DFC(0x65→-1) poke 回 0x65 会整屏黑（关键渲染指针，-1 是该态正常值）。
  - 0x2BC590(2→0) poke 无效。
- 真正的结构差异（base 初始无箭头 vs arrow 返回）：wrapper compact-timer 节点对
  0x2BCCB8(due=500,cb=0xE82F01) 与 0x2BC588(due=100,cb=0xE82F01) 在 arrow 态被 LINK
  （0x2BCCB8.+18/+1C = 0x2BC588），base 态未链接。即取消返回后 wrapper 定时器队列被
  额外 arm，驱动了箭头重绘。与 docs/optwar-advbar-return-stall.md 同构（模态关闭后
  wrapper 残留 timer 节点绘制过期 UI）。
- 另有游戏自身 timer 节点 0x28CA2C(due=100, cb=0x22B001=game+0x4D18)——疑似箭头动画重绘回调。

## 追加取证（memory-poke 因果测试，均不构成干净门控）
- 游戏 RW 全局在 r9 相对区（≈0x268BC0+，模块映像尾部之后；模块 dump 只到 0x268BC0）。
- base(初始无箭头) vs arrow(返回) 在 [0x268BC0,0x269770) 仅 2 字节差：
  0x2691EC(flag 1→0)、0x269758(byte 0xa0→0xc8)。
  - poke 0x2691EC→1：无效。
  - poke 0x269758→0xa0：箭头消失但整屏破(ts_bg=False)，是关键坐标/滚动值，非门控。
- 结论：不存在"翻一个内存标志即干净去箭头且画面正常"的门控。箭头是返回后
  游戏 timer 驱动重绘走了不同控制流路径的产物（非单一状态位）。
- 时序线索：箭头在取消后 ~0.47s(≈一个 500ms 周期)出现；疑与 modal 重复定时器
  恢复/wrapper timer 重挂后的首帧重绘相关。
- host 侧 modal 机制：extChunk[0x34]=suspend 深度；save/restore_modal_repeating_timer
  (arm_ext_executor.c 1646/1655)；save/restore_modal_screen_snapshot(1670+)；
  三处 open/close 调用簇 2338/2390、2633/2636、2989/3012。compact node 布局:
  +0 magic, +4 period(PERIOD_OFF), +8 remaining, +0x14 repeat(REPEAT_OFF)。
- DIAG(SKYENGINE_ARM_EXT_DIAG=1)：payment 时 modalDepth 0→1，取消 1→0；code=1/2 的
  ev[] 全 0（支付结果不经此 event 路径传递）。

## 根因（2026-08-18 由 PC 覆盖率 diff 定论）
- 用 UC_HOOK_BLOCK 覆盖率追踪(aex_diag.c SKYENGINE_PC_COV,COVDUMP socket 命令),对比
  "取消返回画箭头那一帧"窗口 vs 稳态窗口,箭头一次性绘制的 draw-only 基本块**全部**落在
  模块 0x26B850。
- 模块 0x26B850 = **netpay 插件本体**(字符串:netpay.ext/smcheck.ext/advsms.ext/
  dealtimer/"CB when pause!"/TimerState/exRam...)。
- 0x26c03c = netpay 自己的 delta 定时器调度器(message code 2 = timer tick;调度头
  [r9+0x110];node+8=remaining,+12=cb,+16=arg,+24=next)。
- 触发链:wrapper compact-timer 节点(cb=0xE82F01,绑定 netpay 子模块 extChunk)每
  tick → 0xE82F00 投递 code=2 给 netpay helper → netpay 调度器 0x26c03c 处理到期节点
  0x26D9BC(due=500ms,cb=0x26C2CC,~0.47s 计时吻合)→ 0x26C2CC 调 0x26baa8(11,69,...)
  显示"导航箭头"窗口。
- 即:取消计费后 netpay 本该关闭,但其 500ms "dealtimer" 残留并在关闭后触发一次,
  以过期上下文重绘箭头。真机上 netpay 关闭会取消该定时器。
- 为何早先"丢 period==500 wrapper 节点"无效:period-100 的 wrapper 节点(0x2BC588,
  绑定另一个 netpay 子模块 P=0x2BC5AC)也在给 netpay 送 tick;只丢 500 不够。且
  Agent B 的 chunk_p==closed_child_p 判据不命中——节点绑定的是 netpay **子模块** P
  (0x2BC5AC/0x2BCCDC),而 closed_child_p 是 netpay 顶层 P(0x2BCF2C)。

## 修复方向（待验证）
模态关闭(suspend depth>0→0)时,摘除 wrapper compact-timer 队列中所有"wrapper trampoline
节点(cb 落在 [EXT_CODE_ADDR,+code_len))且目标 extChunk 的 P != primary_p_addr 且 !=
m->p_addr"的节点——即返回 primary 后仍指向前台子模块(netpay)的残留 tick 源。纯结构
判据,无 app 指纹。需验证:gfktjc 箭头消失 + 不破坏 smcheck/其它 e2e。

## 完整触发链（2026-08-18 定论，PC 覆盖率 + WATCH 反汇编）
1. 取消(RIGHT_SOFT) → 模态(netpay)关闭,suspend depth 1→0。
2. **guest wrapper 的 resume 循环** `0xE80BE0`(caller lr=0xE80BEB)对全部挂起 chunk 逐一调
   `0xE82EB0`(resume):校验 chunk magic(EXT_CHUNK_MAGIC 0x7FD854EB)→ [chunk+0x34]--(suspend
   深度)→ 深度到 0 时 `bl 0xE83598`(重挂 timer)→ 无条件 `helper([chunk+0x1C]=P, code=5)`。
   本轮对 4 个 chunk 调用:0x2BC54C(P=0x2BC5AC=游戏/primary)、0x2BCC7C、0x2BC8E4、0x2BD3AC
   (后三个 = netpay 子模块)。
3. 对 netpay chunk 的 resume → `helper(P, 5)` → netpay 分派器 `0x26BCF8`(只被调 1 次,来自
   0xE82EF3)→ netpay 自己的 delta 调度器 `0x26C03C`(因挂起期 elapsed 巨大,到期节点立即触发)
   → 回调 `0x26C2CC`。
4. `0x26C2CC`:查询 `0x26BAA8(1,0x20,11,"netpay.mrp","plugins","smsnet.ext")`,返回 0 时
   (0x26C2F0 `cmp r0,#0;bne skip`)→ 走 0x26C2F4 分支 → `0x26BAA8(11,68/69,...)` 显示导航箭头。
   运行时 WATCH 实测该查询返回 r0=0 → 画箭头。
- 即:取消计费后 netpay 本应**关闭/卸载**,模拟器却把它**挂起后又 resume**,其 500ms dealtimer
  以过期上下文触发,SMS 子模块(smsnet)查询返回 0 → 画出导航箭头。真机上 netpay 被关闭,
  该 resume/timer 不发生(或查询返回非 0)。

## 已排除/失败的修复尝试(全部实测无效或不可行)
- 丢 wrapper compact-timer 残留节点(period=500 / 全部绑定非 primary 的 trampoline 节点):
  节点是给 netpay 送 tick 的通道之一,但 dealtimer 在 netpay **自身**调度器里,由 resume 直接
  触发,丢 wrapper 节点不阻止 resume。
- 置 netpay chunk magic=0(想让 resume 跳过):模态关闭的 host 后处理(arm_ext_executor.c ~2358)
  在 **guest resume 循环之后**执行,已经晚了。
- 禁用 restore_modal_repeating_timer / restore_modal_screen_snapshot:无效。
- 删 SMS fixture(channel.sms / 785DBAD6/sms):无效。
- WATCH SET_REG 强制查询结果 r0=1 于 0x26C2F0 / 代码 patch 0x26C2CC→bx lr:未生效
  (unicorn 翻译块缓存 / SET_REG 未落 → 结论不定,但即使生效也只是掩盖症状)。

## 架构性障碍(为什么难修)
- netpay UI 缓冲、位图缓存、调度节点全部 host-mapped(uc_mem_map_ptr)→ UC_HOOK_MEM_WRITE/READ
  不触发,无法用内存 watch 定位/拦截绘制。
- 箭头由 guest 直接 blit 进 0x2001BC(不走 c_function)→ 无法用 host 的 screen-write 接受判定拒绝。
- 堆地址每次运行漂移 → 固定地址 poke 不可靠;代码 patch 受 unicorn 块缓存影响。
- resume 是 guest wrapper 逻辑,发生在 host 模态关闭后处理之前 → host 在 2358 处干预太晚。

## 推荐的修复方向(留待专门跟进)
真机语义:取消计费 = **关闭/卸载 netpay**(不 resume)。模拟器需要在取消路径让 netpay chunk
被关闭而非"挂起→resume"。可能入口:
- host 在把 code=2(模态关闭)回调交给 guest **之前**,对正在关闭的前台子模块(active_p_addr=
  netpay 及其子 chunk)标记关闭,使 guest wrapper resume 循环(0xE82EB0 的 magic 校验)跳过它们;
- 或调查为什么取消走的是"挂起→resume"而不是"关闭"路径(对照 netpay 生命周期事件码 3/4,
  见 docs/optwar-cancel-pay-stall.md);
- 或让 netpay 的 resume 不以过期 elapsed 触发 dealtimer(挂起期冻结 netpay 调度器时钟)。
需要:纯结构判据、无 app 指纹;并回归 smcheck/其它计费用例。

## 决定性确认(2026-08-18)
- 在 guest 模态关闭回调(run_arm_with_sp @arm_ext_executor.c:2096)**运行前**,失效非 primary
  子模块 chunk magic(让 wrapper resume 0xE82EB0 magic 校验跳过)→ **箭头消失(0 帧)**,
  但排除"活动关闭 chunk(active_p_addr)"后箭头又回来 → **触发 dealtimer 的正是活动 netpay
  chunk 自身的 resume**。
- 而失效活动 chunk 会导致取消后停在蓝屏(不返回训练页)→ 活动 netpay chunk **同时**负责:
  (a) 关闭/通知游戏返回训练页;(b) 其 resume 触发 dealtimer 画箭头。二者同 chunk,chunk 粒度不可分。
- 故修复必须**更细粒度**:只 disarm dealtimer 那个节点(cb=0x26C2CC,地址每次漂移)/ 让查询
  (smsnet 激活?)返回非 0 / resume 时重置 netpay 内部调度器 last-tick 时间(0x26C03C:
  base=r9+0x108,last_time=base+0x10,head=base+8)使 elapsed≈0 不过期触发。
  这些都触及 netpay **应用私有**调度器布局/字符串 → 与"禁止硬编码"冲突。

## 结论
根因完全定位:取消计费后活动 netpay chunk 被 resume,其 500ms dealtimer 因挂起期 elapsed 巨大
立即触发,dealtimer 回调查询 smsnet 激活状态返回 0(模拟器用非 SMS 付费,smsnet 未激活)→ 画导航
箭头。真机(真实 SMS 付费)smsnet 已激活 → 查询非 0 → 不画。**本会话未能给出既去箭头又不破坏
取消返回、且不硬编码 netpay 私有布局的 host 修复**。可行方向见上,均需触及 netpay 应用内部或
付费环境(本地 pay-server / modified netpay.mrp 用非 SMS 流)。

## 付费环境调查(方向 2,2026-08-18)
- gfktjc 付费:ENTER 训练项 → netpay `POST /payOneAsTlv` 到 rop.skymobiapp.com(**真实**服务器
  159.75.119.124,来自 src/skyengine_args.c:29 DEFAULT_DNS_MAP)。响应 = 29 字节 nonEntitling TLV
  (`0003F1/len9/"000000006"/044F/len4/0`,与 channel.sms fixture 一致;PREPROP 恒非授权,真机/本地一致)。
- netpay 走 SMS 付费路径,子模块全部加载(按解压尺寸精确匹配):
  smsend.ext=0x26B850(**含 dealtimer 0x26C2CC**),smsnet.ext=0x29BE40,smcheck.ext=0x26D9E0,
  advsms.ext=0x2736A0,netpay.ext(主)=0x2C8B5C。→ **smsnet 确实已加载**,非"加载失败"。
- 整个流程 **未调用 mr_sendSms**(dsm.c:1474 是 stub 返回 MR_SUCCESS;取消发生在确认发短信之前)。
- 主机 SMS 结果投递:table[59] mr_sendSms + m->pending_sms_result → arm_ext_dispatch_pending_sms_result
  (arm_ext_executor.c:1872)投 {MR_SMS_RESULT, MR_SUCCESS} 事件。本用例未触发(没发短信)。
- 结论:付费环境本身正确(真服务器应答、SMS 子模块加载、PREPROP 语义一致)。箭头仍是 smsend 的
  dealtimer 在**取消后 resume 时触发**创建的 UI(0x26C2CC 查询 0x26BAA8(1,...,smsnet.ext) 返回 0 →
  建窗)。即方向 2 收敛回同一根因:取消后 netpay(smsend)被 resume 而非关闭,dealtimer 触发建 UI。
  需确认 0x26BAA8 查询语义(子 Agent 进行中)以定"何为正确 deactivate 状态"。

## 双 Agent 反汇编定论(2026-08-18)——真正根因 = 取消时缺少 CLOSE 事件
- **查询语义(0x26BAA8)**:MPS 事件,查 smsnet.ext 是否为 wrapper per-app 注册表
  ([r9+0xF4+[r9+0x1C]*8],key@node+0x10,loader 0xE80EE0)里的活动子模块;未注册返回 0 → 画箭头。
  但 PREPROP 恒非授权(真机/本地一致),真机该查询同样会 0——故查询不是真差异点。
- **dealtimer 生命周期(smsend.ext=0x26B850)**:节点 R9+0xC,cb=0x26C2CC,周期 500ms。
  - 创建:dispatcher code0(init)→0x26CE30→0x26BE28。
  - **arm**:进 SMS 发送屏/状态时(菜单回调 0x26C194 或状态机 0x26C6C4 state==5,均调 INSERT 0x26BEDC)。
  - **disarm(唯一)**:dispatcher **code1 且 msg->word0==8(CLOSE)** → 0x26BA54 → 0x26CB8C
    (REMOVE 0x26BE7C + 清 magic + free)。无 SMS 完成/pause/resume 的 disarm。
  - dispatcher code:0=init,1=event(msg[0]==8 CLOSE / ==7 主UI),2=timer tick(→0x26C03C 调度器),
    4=pause(no-op),5=**resume(no-op 0x26BDF0)**。"TimerState/CB when pause!" 字符串无代码引用,
    调度器无 pause 守卫。
  - **BUG**:取消时 wrapper resume 只发 code5(no-op)→ 节点仍 armed,last-tick(R9+0x118)未复位 →
    下一次 code2 tick 时 elapsed 巨大 → 触发 0x26C2CC → 画箭头。真机取消发 CLOSE(code1/msg[0]==8)
    → 0x26CB8C 拆除节点 → 不触发。
- **修复方向(= 用户方向 2 的"正确 deactivate")**:取消(模态关闭)时,模拟器应给正在关闭的前台子模块
  (netpay 各 .ext)投递 CLOSE(code=1, msg[0]==8),使其 disarm/teardown,而非仅 resume(code5)。
  纯生命周期语义,非硬编码 app。需验证:箭头消失 + 取消返回训练页正常 + smcheck/其它计费用例不回归。

## 实现验证(2026-08-18)——方向已证实,但干净实现受阻
- 模块身份(按解压尺寸精确匹配):**smsend.ext=0x26B850(dealtimer 所在)**、smsnet.ext=0x29BE40、
  smcheck.ext=0x26D9E0、advsms.ext=0x2736A0、netpay.ext(协调者/活动模态)=0x2C8B5C(closed_child_p)。
- 关键时序(baseline WATCH+DIAG):dealtimer(0x26C2CC)只触发 1 次,发生在 **modalDepth=0(模态已关闭
  之后)** 的 code=2 tick 里(callP=wrapper,r9=0x26D814=smsend rw)。即 **arm 与 fire 都在模态关闭
  之后的后续 tick**。
- 在模态关闭处(2358)读 smsend compact 调度器(rw+scheduler_off=0x108,head@+8/+0xC)**已为空**
  → 关闭时节点尚未 arm,清空无效。
- 投递 CLOSE(code=1,msg[0]==8)到 smsend helper(直接调,复用 resume 方式):disarm(0x26CB8C)会执行,
  但箭头仍在——smsend 被 resume(未卸载)后继续处理 tick、**重新 arm** dealtimer 再触发。
- 投递 CLOSE 到活动协调者 netpay.ext(经 arm_ext_call 路由到 active):箭头消失但**整屏黑**(把负责
  返回训练页的 netpay.ext 也关了)。
- **根本差异**:真机取消 = **卸载/关闭 netpay 子模块**(停 tick、停 re-arm);模拟器 = **suspend→resume**
  (子模块继续运行 → 反复 arm → dealtimer 过期触发画箭头)。reset_child_modules 只清 host 记录,不停
  guest 子模块的 wrapper tick。

## 结论与建议(未落地干净修复)
根因彻底查明:取消计费后 netpay 子模块被 resume 而非卸载,smsend 继续运行并(在模态关闭后的 tick)
重新 arm 其 500ms dealtimer;dealtimer 因挂起期 elapsed 巨大而立即触发,其查询(smsnet 是否为活动
MPS 子模块)返回 0 → 建导航箭头窗口。真机取消会卸载子模块(收 CLOSE code=1/msg[0]==8 → 0x26CB8C
disarm 并停机),故不触发。
干净修复需让模拟器在取消时**卸载/停 tick** 被关闭的 netpay 子模块(而非 resume),这是模态
suspend/resume-vs-unload 语义的较大改动;已试的多种细粒度介入(清调度头/投 CLOSE 事件/失效 chunk)
或太晚、或被 re-arm、或破坏返回。备选(症状级、非"正确"):令 dealtimer 查询返回非 0(smsnet 视为
已注册),可去箭头但掩盖问题。

## 深度修复尝试(方向已选"卸载/停 tick 子模块",2026-08-18)——撞架构墙
- 双 Agent 精确生命周期:dealtimer 节点 R9+0xC,cb=0x26C2CC,500ms。**arm**=进 SMS 屏(0x26C194 arg=0/
  0x26C6C4 state==5 → INSERT 0x26BEDC),**disarm 唯一**=dispatcher code1&msg[0]==8(CLOSE)→0x26CB8C。
  resume(code5)/pause(code4)均 no-op,无 pause 守卫。
- 实现"quiesce"(模态关闭置位 → 后续 code=2 tick 的 guest 运行前:摘除 wrapper compact 队列里指向非
  primary 子模块的 trampoline 节点 + 清空各被关闭子模块自身 compact 调度头)。实测:
  - flag 正确置位(closed_p=netpay.ext=0x2BCF2C),但每次 tick **dropped≈0**——quiesce 运行时 smsend
    调度头为空。即 **arm 与 fire 在同一个 guest tick 内完成**(由 netpay.ext 的 resume 级联驱动),
    guest 运行前的 host 介入抓不到已 arm 的节点。
  - smsend 的 code=2 tick 也不来自可摘的 wrapper compact 节点(dropped 0);疑经 netpay.ext resume 级联
    或 wrapper delta 链。
- 失效 netpay.ext(活动协调者)chunk 可去箭头但**整屏黑**——它同时负责"返回训练页";失效 smsend chunk
  单独无效。即**协调者的一次 resume 原子地既驱动返回、又(级联)触发残留 dealtimer,host 侧不可分割**。
- 结论:干净的"取消即卸载/停 tick netpay 子模块"需要 UC_HOOK 到 app 专属地址(违反禁硬编码)或对模态
  suspend/resume-vs-unload 语义做较大重构。**本会话未能在禁硬编码约束下落地干净深度修复。**

## 待定
1. 游戏侧箭头绘制条件变量（guest 地址）+ 谁写它（静态反汇编 game module）。
2. wrapper 回调 0xE82F00 语义 + host 在 netpay 取消返回路径何处 arm 了残留 wrapper 定时器；
   对照 optwar-advbar 修复，定位最小 host 改动点（禁止硬编码 app/文件指纹）。

## 2026-08-20 续查：当前基线与时序纠正
- 干净基线再次执行目标命令（未开 trace、SDL dummy、无 xvfb），24.5s 后稳定失败：
  `training-select-return.ppm` 的右/左箭头像素分别为 `(248,156,0)`、`(248,168,0)`。
  取消前后仅 174 像素不同，差异框 `[6,149]-[232,161]`；三个训练页正向像素均不变，
  因而确认是训练选择页上叠加箭头，不是卡在支付页。
- 最新基线产物：`/tmp/skyengine-e2e-7mfalN`。最终失败帧 SHA-256：
  `859816f3fb1ab07bbb60ba94c106634d7ccb8b0f7883caf45383d8dc9a5f6651`。
- 重新反汇编 wrapper `/tmp/mod_E80000.bin` 后，纠正上文“resume 直接触发 delta scheduler”的
  表述：`0xE82EB0` 在 chunk magic 合法时递减 `chunk+0x34`，调用 `0xE83598` 重挂 wrapper
  timer，再以 code=5 调 child helper；`smsend` 的 code=5 分支只是返回。真正的插件 delta
  walker 仍由后续 wrapper timer `0xE83710 -> 0xE82F00 -> helper(P,2)` 驱动。
- `0xE82F00` 不检查 chunk magic：它直接从 `chunk+0x08/+0x1c` 取 helper/P 并调用 code=2。
  因而关闭回调之后仅清 chunk magic 无法阻止已经链接的 timer 节点；正确修复还必须按
  wrapper 的真实 compact scheduler 结构解除与已关闭 child chunk 绑定的节点。
- 现有宿主关闭逻辑只把 `closed_child_p` 从 `nested_modules` 记录中移除；
  `arm_ext_has_internal_loader_chunk()` 仍判活的 support EXT 会保留。宿主注册表清理不等于
  guest wrapper timer 队列清理，这正是下一步最小修复的边界。

## 2026-08-20 续查：注册链与 timer 双链的一致性判据
- wrapper `0xE80B80/0xE80CC0/0xE80E28` 证明当前事件层位于 `RW+0x1C`，8 个
  `{head,tail}` 注册桶始于 `RW+0xF4`；注册节点是带 bucket sentinel 的双向链：
  `+0x00=next`、`+0x04=prev`、`+0x0C=extChunk`，空桶为 `{0,0}`。关闭循环对
  当前桶逐个执行 unregister。
- compact scheduler `0xE83538/0xE83598/0xE83710` 证明调度头使用探测出的
  `RW+0x1F4`：queued/current 头为 `+0x0C/+0x10`，节点对应 next 为
  `+0x18/+0x1C`；节点 `+0x0C=callback`、`+0x10=callback argument`。child tick
  的 argument 正是注册节点 `+0x0C` 的同一个 extChunk，callback 与
  `extChunk+0x28` 一致。
- 宿主 `MODAL_FG_SNAPSHOT` 恢复 `RW+0xE0..+0x1AF`，会恢复进入模态前的
  事件注册桶，却不会触及位于 `RW+0x1F4` 的 timer scheduler。取消回调在恢复前已经
  resume/rearm child timer，因此关闭后出现“extChunk 已不在当前注册桶、timer 仍引用它”的
  孤儿 dispatch；这也解释了 smsnet 查询为未注册而 smsend 仍收到 code=2 的表面矛盾。
- 当前可逆实验：只在前台快照实际恢复成功后，先完整验证 8 个注册 hlist 与 queued/current
  两条 timer 链，再摘除 callback/argument 结构指向合法 child extChunk、但 extChunk 已不在
  恢复后任一注册桶的 timer 节点。不 free 节点、不改 chunk magic、不按包或应用分组；若任一
  结构验证失败则不写 guest 状态。下一步先用目标 PPM 验证，再跑 optwar/gghjt 回归。

## 约束
最小改动、加注释、无兜底、无硬编码 if(is_xxx_app)、禁止改测试按键逻辑（仅允许最后 waitFor）。
先修 BUG 再兼容其它用例；`pnpm test:e2e` 不得回归。

## 2026-08-20 续查：孤儿 timer 假设被运行时证据否定
- 在恢复点按真实 registry ABI 枚举后，`guest-close` 与 `host-restored` 的四个 extChunk 完全一致：
  `0x2BC8E4`、`0x2BD3AC`、`0x2BCC7C`（smsend）、`0x2BC54C`（primary）。
  因此 `MODAL_FG_SNAPSHOT` 在本路径没有复活或移除 smsend。
- 关闭后 smsend 的 wrapper timer 节点 `0x2BCCB8` 仍是正常注册对象：magic、chunk/P/helper、
  `chunk+0x24 == timer node` 均合法，且 chunk 可从恢复后的 registry 到达。节点 callback
  `0xE82F01` 是 code-2 trampoline；`chunk+0x28 == 0xE82D4D` 是另一个 wrapper dispatcher，
  上一节“二者一致”的判断错误，现已纠正。
- 因而“删除恢复后不在 registry 的 timer”在目标路径不会删除任何节点，也不能作为修复。
  相关临时源码与诊断已移除。只有 `P != primary` / support EXT 这一类过宽判据能选中它，
  但会误删 optwar 第一次 modal close 后仍需继续工作的 advbar/smsend。
- 对每次 `depth==0` snapshot save 的窄探针意外输出了约 1176 行，已删除且不再运行。首个结构
  合法的 snapshot 已经包含五个注册模块并有活动 child，后续主要为四或五个模块；没有发现
  “先保存 primary-only，随后被 support 状态覆盖”的证据。
- 证据产物：registry/timer 对照为 `/tmp/skyengine-e2e-YiHLQR` 与
  `/tmp/skyengine-e2e-dwyHTY`；snapshot-save 探针为 `/tmp/skyengine-e2e-pKhjh0`。
- 下一步不能继续从 registry/timer 现状猜测卸载意图；需在模块创建/激活时捕获真实父代或
  component generation，再用稳定返回 primary 且该 generation 未重新激活作为 retire 判据。
- 完整 foreground snapshot 差异探针仅发现 `RW+0x100` 的空链 tail 规范化和
  `RW+0x198` 的 helper 槽变化；禁用整段 host restore 后最终 PPM 仍为基线同一 SHA-256，
  因而 snapshot restore 也不是箭头原因。探针产物为 `/tmp/skyengine-e2e-9w13n6` 与
  `/tmp/skyengine-e2e-uYU7di`，源码探针已移除。
- 在关闭后按纠正后的 ABI 同时从 queued/current 链摘除首个合法 non-primary 节点，准确命中
  smsend `node=0x2BCCB8/chunk=0x2BCC7C`，但最终 PPM 仍逐字节等于失败基线。该因果实验
  `/tmp/skyengine-e2e-3uPJFH` 只证明一次性的关闭后摘链不足；它不能单独区分关闭回调内已经绘制
  与后续重新挂链。最终修复不依赖这一区分，见下节的 replacement alias 归属证据。

## 2026-08-20 最终根因与修复：dump restore 错删 replacement alias
- 初次加载的图形 child `file=0x269770,P=0x2BC944,helper=0x26AF19,RW=0x26B74C`，随后同一
  child 以 `file=0x281E88,P=0x2BC944,helper=0x283631,RW=0x283E64` 重新实例化。两份 dump
  的 SHA-256 均为 `8946881263c3cfdcd010feb7da67c85c9a44338a97119d1f1e9c1b96a00d9a6d`，
  helper 相对映像偏移也同为 `0x17A9`；这是同 P、同代码的 replacement，不是两个不同组件。
- game RW 会保留旧实例的 raw exports。现有 `arm_ext_redirect_replaced_code_instance()` 本来就负责
  把这些旧 PC 按相对偏移重定向到当前实例，并从当前 P 恢复正确 R9（提交 `8078044` 已为这条
  gfktjc 路径建立过全量 E2E 证据）。
- 取消支付时 `dump0` 恢复 `[0x2262C8,0x2BC2C8)`：旧图形代码和 game raw-export 表都被复活，
  但复用后的 extChunk/P 位于区间之外。恢复清理因旧 `0x269770` 不再拥有当前 loader tuple 而输出
  `stale_child_drop`，删除了 redirect 所需的旧代码范围 alias。随后旧回调进入 `0x26A8BB/0x26AB21`
  时无法解析 owner，R9 保持 0，并反复落入 `low_zero`。这才是模拟器相对真机的结构性差异；
  smsend dealtimer/MPS 链说明谁发起了箭头相关窗口操作，但不是可安全退休整个组件的依据。
- 最小通用修复保留的只是 **replacement alias**，不复活旧 RW，也不按应用/包名/地址判断。旧记录
  只有在找到以下当前实例时才保留并允许 redirect：相同 P、不同 file base、相同长度且 `len>8`、
  相同 helper 相对偏移、`[file+8,file+len)` 完全一致，并且候选的 `P+0x0C` 指向一个经
  `require_confirmed=1` 验证且 P/helper 与候选记录一致的 private-loader tuple。显式关闭的 child P
  仍不得靠 alias 保留。
- 该判据统一用于 overlap drop、dump0 primary reconciliation、modal child reset 和旧 PC redirect；
  redirect 直接使用判据返回的 confirmed candidate，避免另一次按 P 反向查找选中其它 stale alias。
- 因果 probe（`/tmp/skyengine-e2e-U2KCNj`、`/tmp/skyengine-e2e-bVi9K3`）和最终无诊断运行
  （`/tmp/skyengine-e2e-xUA80j`、`/tmp/skyengine-e2e-5l5pvR`）均通过目标用例。最终
  `training-select-return.ppm` SHA-256 为
  `d061042a96e7ccb0d5eb2a370a141b8b6020db4ab7efb5bc0525e3390b843098`，并与取消前
  `training-select.ppm` 逐字节一致；左右箭头像素恢复为 `(64,68,64)`，三个训练页正向像素仍为
  `(104,76,0)`、`(64,68,64)`、`(152,152,152)`。
- 定向兼容回归 4 个文件、10 个用例全部通过：`optwar/game-play`、`optwar/speed`、
  `optwar/advbar`、`gghjt/download-plugin`（含 60 秒付费超时返回重进）。
