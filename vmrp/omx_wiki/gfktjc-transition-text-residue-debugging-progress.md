---
title: "gfktjc transition text residue debugging progress"
tags: ["gfktjc", "rendering", "ppm", "disassembly", "progress"]
created: 2026-08-15T04:10:05.655Z
updated: 2026-08-15T13:32:45+08:00
sources: []
links: []
category: debugging
confidence: high
schemaVersion: 1
---

# gfktjc transition text residue debugging progress

## 2026-08-15 初始基线

目标: 修复 gfktjc-v1005 从图形加速提示切换到开启音乐界面后旧文字残留。约束: 不使用 xvfb、不启用海量 trace、必须深入反汇编、最小通用修复且代码注释解释原因、最终运行目标用例和其余 e2e 兼容性验证。

当前工作树原有改动: docs/prompt.md、vitest.config.ts，以及未跟踪 test/e2e/gfktjc/render.test.ts 和 test/fixtures/gfktjc-v1005.mrp，均视为用户输入并保留。构建产物为 build/skyengine；CMake 无 vmrp target。

目标测试的可见契约: 首屏 (116,62) 为 [240,180,64]；RIGHT_SOFT 后该像素必须变化且音乐界面 (111,132) 为 [240,180,64]。待验证: 实际 PPM 残留范围、guest 转场指令/API、宿主屏幕缓冲/刷新语义。

并行调查: PPM复现、MRP反汇编、宿主图形路径、历史相似修复、回归测试地图。

## 2026-08-15 基线复现与历史约束

已证实:

- `VMRP_E2E_KEEP_TMP=1 pnpm vitest run test/e2e/gfktjc/render.test.ts` 稳定失败于 `(116,62)` 仍为 `[240,180,64]`。保留产物: `/tmp/skyengine-e2e-Ruxt6Y/main.ppm` 与 `bgm-select.ppm`。
- 两帧均为 240x320。转场仅有 244/76800 像素变化,全部是黑色变橙色;首帧 2837 个橙色像素 100% 保留。旧正文残留位于 `y=31..77`(2739 像素),旧软键文字位于 `y=304..314`(98 像素);新音乐提示只在 `y=130..140` 增加 198 像素。
- 因此新界面确实执行了局部文字绘制,异常不是文字 API 重复调用或 RGB565 转换错误,而是旧前景未被可见清除。

已否决候选:

- `src/arm_ext/aex_table.c` 的 table[122] 全屏黑清除抑制曾与 PPM 形态吻合,但转场区间的动态调用序列已证明没有 table[122],因此它不是本问题根因。
- 该特殊规则来自提交 `2fea5d9`,用于保护 gzwdzjs 的另一种合法序列:全屏黑只重置 backing cache,随后局部重绘并显式 present;若直接恢复全屏 damage,callback 退出会把应用未提交的黑区错误送显。因此不能简单删除 `full_black_clear` 判断。
- “pending full-black clear”设计虽然可兼容两类历史语义,但因目标转场未调用 clear 而不应实施;修改它只会扩大改动面且不能解决 gfktjc。

## 2026-08-15 转场反汇编反证

已证实:

- 解压映像:动态 `game.ext` base=`0x2262E8`,len=`0x422D8`;`graphics.ext` base=`0x269770`,len=`0x1FD4`。
- 图形加速页出现前,`graphics.ext+0x13AE` 通过 LR=`0x26AB21` 调用一次 table[122],参数 `x=0,y=0,w=240,h=320`;之后 `game.ext+0x21986` 通过 LR=`0x247C71` 调用 table[29],完整提交 `0x2001BC` 的 240x320 framebuffer。
- 精确以 RIGHT_SOFT 前后的 E2E 标记切分调用日志后,转场区间没有 table[122]/table[118]/table[123],却有 10 次相同的 table[29] 全屏提交。因而 SDL 未刷新、damage 未合成、DrawText 背景透明均不是首要原因;被提交的 framebuffer 本身仍含旧页像素。
- `game.ext+0x21954` 的 present 包装函数在 table[29] 前含一个可选 callback 调用。下一步需确认该槽在转场前后的值/所属模块,并核对 table[14] memset、table[3]/[4] copy、direct guest store、graphics 子模块退出和 modal snapshot 状态,找出 framebuffer 应被重建却未重建的协议断点。

## 2026-08-15 旧 graphics 映像失效的根因证据

进一步的 guest framebuffer 写探针和逐 PC 寄存器观察已将根因收敛到 private-loader 子模块替换协议,而不是屏幕合成:

- 旧像素 `(116,62)` 与新提示像素 `(111,132)` 都由 `skyfont.ext` 的同一文字栅格化 PC `0x27AADC` 写入,所以字体写入路径正常。
- `graphics.ext+0x13AE` 的全屏清除路径先从运行映像 `file_base[0]` 取私有 module record,再从 `record[122]` 取 `DrawRect` 桥并 `blx`。首次 graphics 实例的 `file_base=0x269770`,其中 `record=0x2BC69C`,`record[122]=0x101E8`,因而全屏清除正常执行。
- RIGHT_SOFT 后 wrapper 在同一 `P=0x2BC944` 上装入新 graphics 实例:新 `file_base=0x281E88`,新 helper/RW 分别为 `0x283631/0x283E64`,record 仍为 `0x2BC69C` 且 `record[122]` 正常。
- primary game 保存的 graphics 导出函数仍指向旧代码 `0x269770+offset`。wrapper teardown 随后把旧映像头改写为 `{0x0005A7A0,0x00001FD8}`;写入发生在 `cfunction.ext` 的 wrapper 路径 `PC=0xE8238C, LR=0xE81E03`。
- 因而旧代码再次执行 `graphics.ext+0x13A4/+0x13A8/+0x13AE` 时,从旧 `file_base[0]` 读到的已不是 record `0x2BC69C`,而是 allocator/teardown 元数据 `0x5A7A0`;最终 `record[122]` 为 0。每个 tick 的全屏清除都退化为跳转 0,而随后 table[29] 仍完整提交保留旧文字的 guest framebuffer。

这也解释了为何 table[122] 调用日志在转场后完全消失:不是应用没有请求清除,而是调用在进入 host table bridge 之前已经因陈旧导出地址和失效旧映像头而跳到 0。稳定 E2E 中 `modalDepth=0`,因此 modal snapshot/foreground cover/full-black damage 均不是该路径的修复点。

待确认的通用契约: wrapper 写入 `{old_file_len/allocator metadata}` 是释放旧 child 映像的正常 teardown;同一 `P` 被新 file/helper/RW 替换后,宿主应如何让 primary 保留的旧导出函数继续解析到有效 runtime header,或如何刷新它们。修复必须由模块登记/替换事实驱动,不得依赖 graphics 名称、固定偏移或清屏行为。

## 2026-08-15 allocator 修复实验及回归否决

最终反汇编/定点观察确认:

- `cfunction.ext+0x2320` 是 wrapper compact `mr_free` 入口,原始参数保留在 `R0/R1`;`+0x23AC` 是返回点。它把长度按 8 字节对齐后维护 `{next_offset,len}` free-list。
- graphics teardown 对旧 ER_RW allocation cell 的精确 free 为 `0x26B748/0x104` (`P[0]=0x26B74C,P[4]=0x100`),随后对旧映像精确 free `0x269770/0x1FD4` (allocator cell `0x1FD8`)。
- 宿主原有 return hook 会收集所有已登记模块映像/ER_RW,把它们从刚形成的 compact free-list 节点中切除。由于旧 graphics 仍登记,这两次合法 teardown 都被误当作“包含 live code 的 enclosing free”;replacement 因而不能 first-fit 复用旧地址。
- game RW `+0xD3C..+0xD5C` 保存 graphics selector 发布的 9 个原始导出地址。`graphics.ext+0xFD0` 发布该表后不会在 replacement 时改写 game 的保存副本;地址复用本可让这些地址继续有效。

曾实验在 compact free 入口按精确映像/ER_RW cell 退休登记,使 first-fit 恢复原地址。目标用例与 PPM 通过,但完整 e2e 的 `geyaxz/boot-to-home` 和 `geyaxz/play` 稳定失败。以独立 `HEAD` worktree 构建的基线二进制在相同环境/测试下通过,证明这是该实验引入的真实回归。进一步收窄为仅精确映像 free 仍回归,所以不能通过改变 wrapper allocator 地址序列修复;该方案已完整移除。

## 2026-08-15 最终通用修复

最终修复保持 compact allocator、registered storage protection 和所有 teardown 顺序不变,只修复执行器对 replacement 代码身份的解析:

- `UC_HOOK_BLOCK` 已经按当前 PC 的 registered module 修正 R9。现在若该 PC 属于旧实例,且 registry 中存在同一 `P` 的更新实例,则进一步验证两者 `file_len` 相同且跳过运行时 header 的 `[+8,file_len)` 不可变映像体逐字节相等。
- 上述证据同时成立时,按 `old_pc-old_file` 的相对偏移重定向到 `new_file+offset`,并以新实例的 P/RW 修正 R9。旧、新模块只是同一 PIC payload 的不同 runtime instance;不同 child 即使碰巧复用 P,也会因长度或完整 body 不同而拒绝重定向。
- 重写 PC 时保留当前 CPSR Thumb 状态。初版只写偶数目标地址会让 Unicorn 把新位置的 Thumb 字节按 ARM 解码,trace 在 `0x282DB4` 复现 `UC_ERR_INSN_INVALID`;携带 Thumb 位后目标与 `geyaxz` A/B 回归同时通过。
- 判断不包含应用名、模块名、selector 值、graphics 函数偏移或屏幕行为,也没有清屏兜底。

验证:

- 构建 `cmake --build build --target skyengine --parallel` 成功。
- 最终 relocation 实现下,`pnpm vitest run test/e2e/gfktjc/render.test.ts test/e2e/geyaxz/boot-to-home.test.ts --reporter=verbose` 为 2 files / 3 tests 全通过。
- 最终实现的 PPM 产物为 `/tmp/skyengine-e2e-hKvluZ/main.ppm` 与 `/tmp/skyengine-e2e-hKvluZ/bgm-select.ppm`。两帧均为 240x320,共有 3,051 像素变化;首帧 2,837 个橙色像素中 2,807 个被清除,仅 30 个与新底栏字形几何重合;旧正文 `y=31..77` 的橙色像素残留为 0;新音乐提示 `y=130..140` 保持 198 个橙色像素。
- 重点回归覆盖 golden frames、gzwdzjs、gtlbd、optwar、dota 和 geyaxz,结果为 6 files / 9 tests 全通过。
- 完整 `pnpm test:e2e` 门禁为 37 files / 64 tests 全通过。
