# optwar 点击广告 UC_ERR_FETCH_UNMAPPED 分析

## 问题

`pnpm vitest run test/e2e/optwar/game-play.test.ts -t 广告` 执行后报错：

```
arm_ext_executor: uc_emu_start(0xE800B0) failed: 8 (Invalid memory fetch (UC_ERR_FETCH_UNMAPPED))
```

预期：不报错。

## 已知事实

- 分支：fix/optwar-stuck（含 mr_sleep 虚拟时钟快进修复）。
- vitest 本身报 PASS（用例末尾只是 `engine.delay(60_000)`，无断言拦截该错误），
  报错出现在 skyengine 子进程 stdout。
- 内存布局（src/include/arm_ext_internal.h）：
  - EXT_BASE_ADDR=0x10000，EXT_MEM_SIZE=16MB → [0x10000, 0x1010000)
  - EXT_HEAP_ADDR=0x200000，EXT_STACK_ADDR=0xE00000，EXT_CODE_ADDR=0xE80000
  - 0xE800B0 = EXT_CODE_ADDR + 0xB0，位于 16MB 主映射内 → start 地址本身应已映射。
  - 推断：报错的 `start` 只是本次 uc_emu_start 的入口；真正 unmapped 的
    fetch 目标是执行途中跳转到的 PC（见 dump_pc_ring / dumpREG 输出）。
- 报错打印点：src/arm_ext/aex_exec.c:260（run_arm_with_sp）。

## 内存布局结论（子 Agent 调查）

- 0xE800B0 = EXT_CODE_ADDR(0xE80000)+0xB0 = wrapper(cfunction.ext) 的
  mrc_extHelper 事件入口（ARM→Thumb 跳板），是 `m->helper_addr` 的典型值。
  `uc_emu_start(0xE800B0) failed` **不代表 0xE800B0 未映射**——它是每次
  事件/定时器回调的正常起始 PC，真正故障点是报错时的 crash PC。
- 插件（netpay/advbar/game.ext/浏览器插件）加载在 bump 堆 [0x200000,
  0xE00000)，无固定基址；bump 分配器跳过 [0xE00000, 0xE80000+code_len)。
- 16MB 主映射区 [0x10000, 0x1010000) 之外的 guest 地址（如插件里未重定位
  的指针、被踩坏的函数指针指向 0x1010000 之上）才会触发 FETCH_UNMAPPED。
- 诊断手段：`hook_invalid`（arm_ext_executor.c:782）无条件打印
  invalid addr/crash PC/±256B dump 到 /tmp/skyengine_crash.bin；
  `SKYENGINE_ARM_EXT_TRACE_PC` 有 64 条 PC 环形缓冲；
  `SKYENGINE_ARM_EXT_DIAG` 打层状态。
  （注意：实际 env 前缀需查 aex_diag.c，可能是 VMRP_ARM_EXT_*。）

## 崩溃现场（vitest 运行 12:47, artifact /tmp/skyengine-e2e-u5jHWl）

```
invalid memory UC_MEM_FETCH_UNMAPPED addr=0x20411280 size=4
crash PC=0x20411280 (arm)  last_file=0x24FE68..0x25501C
R0=R4=0x0025530C R1=0 R2=0x100 R3=0x20411280 R9=0x225E60
SP=0x345D2C LR=0x00247371
stack: 0x2804 0x9 0x0 0x24E508 0x0 0x23DECC 0x24E530 0x0
       0x2457A1 0x249887 0x24E530 0x23DECC 0x24E530 0x24A8DB 0x236469 0x24E508
```

- 时序：启动 → advbar 向 freeads.51mrp.com(POST /adsystem/Ads/ClientRequest,
  body 91 字节二进制) → click(227,301)（BGM 选“否”）→ my_recv 2048 字节
  广告应答 → my_closeSocket → **跳转 0x20411280 (unmapped) 崩溃**。
- 崩溃入口是 wrapper 事件入口 0xE800B0（正常），真实故障 PC=0x20411280，
  由 blx R3 类调用产生（R3=PC）。LR=0x247371 在 **advbar.ext** 模块内。
- 模块布局（trace 运行确认，bump 布局跨运行稳定）：
  - 模块1 game.ext: file=0x2263A0 len=96268, helper=0x236245, P=0x2BC77C
  - 模块2 smsend.ext: file=0x23FF10 len=5880, helper=0x240DE9, P=0x2BCB54
  - 模块3 advbar.ext: file=0x241F40 len=52548, helper=0x249271, P=0x2BCF2C
  - LR 文件内偏移 = 0x247371 - 0x241F40 = **0x5431**
- advbar.mrp 内容: window_01/02/03.bmp, title.bmp, advbar.ext(41158, 压缩)。
- **复现是数据相关的**：手工运行(auto-click)同样时序不崩；vitest 路径
  (E2E socket + cpSync preserveTimestamps 工作区) 3/3 崩。广告服务器
  (159.75.119.124) 返回内容会轮换 → 疑似特定广告数据触发解析 bug。
- 已加 TEMP-DIAG（提交前删除）：
  - arm_ext_executor.c hook_invalid: VMRP_DUMP_GUEST_MEM=1 → 崩溃时 dump
    16MB 到 /tmp/skyengine_guest.bin
  - network.c my_send/my_recv: VMRP_DUMP_NET=1 → 原始字节存
    /tmp/skyengine_{send,recv}_N.bin

## 反汇编分析（guest dump 已捕获）

崩溃指令（advbar.ext, Thumb）：
```
247360: ldr r3, [pc,#120]  ; 0x5EC
247366: add r3, r9
247368: ldr r3, [r3]       ; r3 = *(R9+0x5EC)  导入槽(memset)
24736e: blx r3             ; r3=0x20411280 → FETCH_UNMAPPED
```

关键事实：
- advbar 自己的 RW(0x24EC8C) 槽位是好的：+0x5EC=0x10038(桥接表 memset)。
- 崩溃时 R9=0x225E60 = **wrapper 的 RW**（含 wrapper UI 中文文案），
  *(0x225E60+0x5EC)=0x20411280 只是 wrapper RW 里无关数据，不是被踩。
- 函数入口时 R9=0x23DBB4 = **game 的 RW**（由 R6=R9+0x6B8、R7=R9+0x5F0
  的崩溃现场值反推），也不是 advbar 的。→ 整条链路 R9 全错。
- 调用链（栈回溯）：0x24A8DB → 0x249882(bl 0x24733C) → 崩溃函数。
  r0 参数 = 0x24E508 = "http://appstore.51mrp.com/wap/appbox"（广告目标URL）。
- mrc ABI 的 R9 切换协议（wrapper cfunction.ext）：
  - e83d70: r0=旧R9, R9=wrapper RW（进 wrapper glue 时调用）
  - e83d6c: R9=r0（出 glue 时恢复调用者 R9）
  - 插件映像头 8 字节被 loader 补丁：+0=helper struct(0x2BCC44:
    [0]=wrapper malloc 0xE82941,[4]=free 0xE828AD,[8..]=桥接表), +4=P。
- 宿主侧 R9 管理（arm_ext_executor.c hook_restore_r9 → 
  arm_ext_sync_r9_for_code_addr，逐 basic block）：
  - PC 在 wrapper 段：若 R9==任一 nested rw → 强制 R9=wrapper rw
  - PC 在 nested 模块段：强制 R9=该模块 rw（多实例有豁免）

### 根因假设（待 trace 验证）

1. game 直接 blx advbar 回调，进入时 R9=game rw；若 advbar 尚未登记进
   nested_modules（崩溃运行里广告响应早于登记），sync hook 不纠正 →
   advbar 代码全程用错 R9。
2. advbar malloc thunk 因 *(game_rw+0x68C)=0 走 PC 相对 fallback →
   wrapper malloc 0xE82941。进入 wrapper 段第一个 block 时宿主 hook 抢先
   把 R9(=game rw, 是 nested rw) 改成 wrapper rw 0x225E60，随后 e83d70
   保存的"旧R9"已是被改后的 0x225E60 → e83d6c 恢复的也是 0x225E60 →
   malloc 返回后 R9=wrapper rw → *(0x225E60+0x5EC) 垃圾指针 → 崩溃。
3. 正常运行不崩是因为 advbar 已登记，每个 block 的 sync hook 把 R9 拉回
   advbar rw，掩盖了同样存在的 wrapper 入口预改写问题。

## R9 探针结论（VMRP_R9_DIAG 运行 #4）

崩溃窗口逐 block sync 记录：
```
R9DIAG sync pc=0x24733C r9=0x23DBB4 nested_count=1 pending=0x0+0x0
R9DIAG sync pc=0x247350 r9=0x23DBB4 nested_count=1
R9DIAG sync pc=0x247358 r9=0x23DBB4 nested_count=1
R9DIAG sync pc=0x247360 r9=0x225E60 nested_count=1   ← malloc 返回后已是 wrapper rw
→ invalid memory FETCH_UNMAPPED 0x20411280
```

**关键**：崩溃时 nested_modules 只有 1 条（primary game）——advbar 的
记录不存在，因此 sync 无法把 R9 纠正回 advbar rw。R9 一路错下去：
1. 进 advbar 代码时 R9=game rw（跨模块调用后宿主/veneer 链丢失了 advbar rw）；
2. advbar malloc thunk 的 [r9+0x68C] 槽在 game rw 下=0 → 走 PC 相对
   fallback → wrapper malloc 0xE82941；
3. PC ring 证实 wrapper malloc 自身的 e83d70/e83d6c 保存/恢复对**正确执行**
   （#60-63），但它恢复出来的是 0x225E60——说明进 wrapper malloc 时 R9 已被
   宿主 hook（wrapper 段分支：R9==nested rw → 强制 wrapper rw）提前改写，
   e83d70 保存的就是已污染值；
4. 回 advbar 后 R9=wrapper rw → *(0x225E60+0x5EC)=0x20411280 → blx → 崩。

嫌疑链：advbar 曾注册（正常运行 trace 可见 "synced internal nested
helper=0x249271"），之后可能被 `arm_ext_retire_modules_overwritten_by_data_read`
→ `arm_ext_drop_overlapping_stale_nested_modules` 丢弃（table[44] 数据读与
模块映像重叠即除名，即使模块仍在运行）。崩溃时 last_file=0x24FE68+0x51B4
是一次大数据读。待运行 #5（record/drop 生命周期探针）确认。

## 根因（已确认，运行 #5 生命周期探针）

运行 #5 完整生命周期：
```
R9DIAG record nested file=0x2263A0+0x1780C  (game)
R9DIAG record nested file=0x23FF10+0x16F8   (smsend)
R9DIAG record nested file=0x241F40+0xCD44   (advbar)
... 广告应答到达 ...
R9DIAG record nested file=0x24FE68+0x51B4   (广告触发新插件 staging)
R9DIAG sync pc=0x24733C nested_count=1      ← 注册表被清到只剩 primary！
→ FETCH_UNMAPPED 崩溃
```
且全程 **没有任何 drop 事件** → 清空者是 `arm_ext_reset_child_modules`
（arm_ext_executor.c，模态框关闭路径 suspend 1→0 的两处调用），它无条件
删除所有非 primary 模块记录。

完整因果链：
1. 广告流程中 wrapper suspend 计数 1→0（模态关闭），宿主调
   arm_ext_reset_child_modules 把 smsend/advbar/新插件的记录全部清掉。
2. advbar 仍在运行（广告 UI 归它），但代码段已无归属记录 →
   hook_restore_r9 的逐 block R9 纠正不再覆盖 advbar 代码段。
3. 跨模块调用（game↔advbar↔wrapper glue）中宿主在 wrapper 段入口
   （e83d70 保存 R9 之前）就强制改写 R9，guest 自己的保存/恢复协议保存
   到的是污染值 → 调用返回后 R9 永久变成 wrapper RW。
4. advbar 按 R9+0x5EC 读 memset 导入槽 → 读到 wrapper RW 里的无关数据
   0x20411280 → blx → UC_ERR_FETCH_UNMAPPED。

## 修复

`src/arm_ext_executor.c` `arm_ext_reset_child_modules`：模态关闭清理时，
除 primary 外，凡 `arm_ext_has_internal_loader_chunk()` 证实仍处于加载
状态（heap 上存在描述该映像的合法 extChunk，映像头 8 字节仍是 loader
补丁的 record/P、P+0x0C 反向指回 chunk）的模块记录一律保留。已卸载/
被覆盖的子模块 chunk 校验必然失败，仍按原语义清除——不含任何应用指纹。

## 进度

- [x] 复现路径确认（用例走到"进入广告"后 60s 等待期间报错）
- [x] 收集完整 stdout（VMRP_E2E_KEEP_TMP=1 保留 artifact-dir/stdout.log）
- [x] 定位 unmapped PC 与调用链（dump_pc_ring + 反汇编 + guest dump）
- [x] 根因 & 修复（arm_ext_reset_child_modules 保留仍加载中的模块）
- [x] 修复验证：广告用例 R9 全程正确(0x24EC8C)，0 条 invalid memory
- [x] TEMP-DIAG 探针全部移除（guest dump/net dump/R9DIAG）
- [ ] 全量 e2e 回归
  - 第一轮：57/58 通过；唯一失败 gghjt「下载付费插件 - 返回重进」
    (wait_draw_timeout)，单独重跑仍失败（确定性），其余 4 个 gghjt
    用例通过。该 reset 逻辑正是 8ac50f8「重构模态框处理」为 gghjt/gxdzc
    引入的——初版修复（chunk 存活即保留）对 gghjt 过宽：取消下载后
    netpay 下载 UI 子模块的 extChunk 未被 wrapper 释放，记录被保留，
    干扰 wrapper 重进下载界面的分发。
  - 基线（无修复）gghjt 3 用例通过 → 失败确由初版修复引起。
  - 修复 v2：`arm_ext_reset_child_modules(m, closed_p_addr)`——模态关闭时
    **本次关闭的前台子模块**（关闭瞬间的 active_p_addr，非 primary/非
    wrapper）记录无条件清除（gghjt 语义），其余模块记录按 extChunk 存活
    保留（optwar 语义）。两处调用点在覆盖 active_p_addr 前捕获该值。
  - 修复 v2 验证：gghjt 全 5 用例 —— 「返回重进」恢复通过；「下载完毕
    付费超时返回重进」在一次夹带中途重编译的运行中像素失败，干净重跑
    通过（失败为二进制热替换所致，非代码问题）。
  - **最终全量回归：34 文件 / 58 用例全部通过**（含 optwar 点击广告、
    gghjt 全 5 用例、gxdzc、dota、talkcat 等模态/子模块相关用例）。

## 结论

BUG 已修复。最终改动仅 3 处（src/arm_ext_executor.c +
src/include/arm_ext_executor.h）：
1. `arm_ext_reset_child_modules` 增加 `closed_p_addr` 参数：无条件清除
   本次关闭的前台子模块记录；其余记录按 extChunk 存活验证保留。
2. 两处模态关闭调用点在覆盖 active_p_addr 前捕获关闭者 P 并传入。

## 后续问题：进入广告阶段卡顿（同用例，2026-07-30 下午）

用例末段（移动光标→进入广告→结束）耗时 ~28s（预期 ~8s）：
`KEY UP` 命令耗时 10s、`KEY ENTER` 耗时 14s。

**排障路径**：table 调用时间戳 → 无 >300ms 空洞（guest 一直在跑）→
E2E 命令/响应时间戳 → 卡在 KEY 命令内部 → keyEvent/timer() 单次耗时
探针 → 单次都 <300ms → KEY-BOUNDARY 探针：`enter arm=398 dispatched=342`
（积压 56 代）、`enter arm=772 dispatched=541`（积压 231 代）。

**根因**：optwar 广告页以 ~10ms 节拍高频 `timerStop/timerStart`
（table[31]/[32]，每秒近百代）。`timerStart` 用 `SDL_RemoveTimer+SDL_AddTimer`
换代，但旧一代 timer 的到期回调可能已把事件推入 SDL 队列；主循环对每个
timer 事件都无条件执行完整 `timer()` dispatch（每次 50-120ms），入队速率 >
分发速率 → SDL 事件队列积压成百上千个**陈旧 generation** 的 timer 事件，
注入的按键事件排在其后，e2e 的 timer-boundary 等待要先消化全部积压。

**修复**（src/main.c 主循环，最小改动）：timer 事件出队时校验
`generation == timerPendingGeneration` 才分发；不匹配即为已被
stop/替换的旧代事件，直接丢弃。真机语义：mr_timer 单实例，stop 后旧
定时器不存在，其到期通知不应再触发 tick。

**效果**：末段 28s → 3.3s（移动光标→进入广告 3.0s、进入广告→结束 0.2s），
用例通过。TEMP-DIAG 探针已全部移除。

**最终状态**：debug 代码全部清理后干净构建复测——移动光标→进入广告 1.1s、
进入广告→结束 0.2s（早前的 3-4s 是 TEMP-DIAG 探针 stdout 开销放大所致）。
全量 e2e 回归 34 文件/58 用例通过（timer 修复轮）。
