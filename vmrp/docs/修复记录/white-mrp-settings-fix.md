# white.mrp settings BUG 修复进度

## 任务
修复 `test/e2e/white/settings.test.ts` 执行时出现的 "table[63/64/65] not implemented" 问题。
对接 native 功能，让 white.mrp 调用原生设置界面后能正常进入。

## 修复内容
- `src/mythroad/dsm.c`:mr_menuCreate 返回自增 handle(避开 0=失败约定),mr_menuSetItem/Show 返回 MR_SUCCESS。
- `src/arm_ext/aex_table.c`:新增 aex_t063/064/065 桥接到 dsm.c 的 menu 函数。
- `src/arm_ext_executor.c` 与 `src/include/arm_ext_host.h`:补充 mr_menuCreate/SetItem/Show 的 extern 声明。

## 验证
- "not implemented" 错误已不再出现（无 `arm_ext_executor: table[63/64/65] not implemented` 日志）。
- trace 显示 white.mrp 一次性调出原生菜单（一次 table[63-65] 后无循环），与修复前死循环对照。
- 跑 gxdzc/cookie/gghjt/gsht/gtxzj 等 e2e 测试，全部 16 用例通过，无回归。

## 测试卡点（独立 BUG）
- `engine.key('DOWN', 1_000)` 的 `wait_draw` 超时（current=4 target>4）。
- 调试事件日志确认 `mr_event` 正常投递（code=0/1 p0=0xD/0x14）。
- wrapper 画菜单走 `blx ip` 直接到 `EXT_TABLE_ADDR+0x1e8`（table[122] DrawRect bridge）或 `EXT_TABLE_ADDR+0x1e0`（table[120] DrawBitmapEx bridge），**绕过 `mr_drawBitmap` (table[29]) 路径**。
- 关键证据:trace 显示 table[122]=1、table[120]=32、table[29]=4。DrawRect 与 DrawBitmapEx 直接写 mythroad screen buffer,跳过 `guiDrawBitmap`,因此 `guiDrawBitmapCount` 不增长。
- 该卡点是 wrapper 设计使然(状态机不响应 KEY 重绘),非 mr_menuCreate/SetItem/Show 未实现引起。

## 调研备选方案
1. **gtk 弹窗方案**: 引入 GTK 依赖;e2e headless(SDL_VIDEODRIVER=dummy)且禁止 Xvfb,无法验证;且 gtk 不能解决 wrapper 不调 table[29] 的问题
2. **SDL 模态菜单**: mr_menuShow 阻塞在主线程;~150 行;headless 可验证
3. **aex_t120/122 计数修正** (已尝试): 试过,让 DrawRect/DrawBitmapEx 也递增 `guiDrawBitmapCount`,但发现: 记录帧的副作用(e2e 帧 ring buffer 仍由 `guiDrawBitmapWithStride` 写入,DrawRect/DrawBitmapEx 不写)会让 cookie 等依赖 `SCREEN_DRAW N` 读帧的测试失败,出现 `ERR screen_draw_failed`。**已回退此变更。**
4. **保持现有修复**: 不继续改 white.mrp,等 4 不再卡 4,其它 16 个 e2e 全过(已验证)

## 进展
- 2026-08-05: 已复现,已识别 table[63-65] = mr_menuCreate/SetItem/Show
- 2026-08-05: 已实现 dsm.c stub 返回自增 handle 与 MR_SUCCESS
- 2026-08-05: 已添加 aex_t063/064/065 桥接
- 2026-08-05: 已修复 "not implemented" 错误;所有非 white 测试通过
- 2026-08-05: 已反汇编确认 wrapper 直接调 `table[122]`/`table[120]` 画菜单
- 2026-08-05: 尝试计数修正被 cookie test 帧断言回退,留待 SDL 模态菜单或更大重构
- 2026-08-05: white 测试卡在 wrapper state-4 不重绘(独立 BUG,需 modal 菜单或 wrapper 重构)

## 2026-08-06：菜单 E2E 输入修复

### 复现与根因

- 修复前运行 `pnpm vitest run test/e2e/white/settings.test.ts`，第一次打开原生菜单的
  `KEY ENTER` 在约 38 秒后报 `Timed out waiting for response to KEY ENTER`。
- `main.c` 必须等 `dispatch_key_down -> event -> table[65] -> mr_menuShow` 返回后，
  才能调用 `complete_e2e_key_event`。旧 `native_modal_menu_show` 却在这条调用栈内进入
  `SDL_WaitEventTimeout` 嵌套循环，因此 E2E 控制线程永远收不到 KEYDOWN 回执；物理键
  没有这项回执等待，所以表现为“手动 ENTER 有响应，测试 ENTER 无响应”。
- 嵌套循环还会从 SDL 队列取走 timer/E2E user event 后直接丢弃；filter 返回 0 并不等于
  事件回到了主循环。旧注释关于 SCREEN/timer 能继续执行的判断不成立。

### 反汇编证据

从 `test/fixtures/white.mrp` 解出的 33188 字节 `cfunction.ext`（运行基址
`0xE80000`）显示：

- `0xE83F7C` 取 host function table `+0xFC`，即 `table[63] mr_menuCreate`；
- `0xE83FC4` 取 `+0x100`，即 `table[64] mr_menuSetItem`；
- `0xE83FDC` 取 `+0x104`，即 `table[65] mr_menuShow`；
- `0xE842BC..0xE842C0` 只取 menu handle 后尾调用 `mr_menuShow`，没有等待选择；
- `0xE84168` 独立处理 event code 4 (`MR_MENU_SELECT`) 并以参数作为 item index；
- `0xE84194` 独立处理 event code 5 (`MR_MENU_RETURN`)。

这与 `mrc/mrc_base.h` 的公开契约一致：`mrc_menuShow` 立即返回
`MR_SUCCESS/MR_FAILED`，选择/取消稍后通过 `mrc_event` 到达。旧阻塞实现违反 ABI。

### 最小通用修复

- `native_modal_menu_show` 只建立状态、绘制菜单并立即返回正 handle，不再创建嵌套
  SDL event loop。
- 菜单输入按 `native_text_widget` 的既有架构进入 `skyengine_runtime_event` 公共漏斗，
  使用 `MR_KEY_*` 语义处理，不依赖 SDL keycode，也没有应用名/包名判断。
- 菜单层记录自己接管的 `MR_KEY_PRESS`，即使选择回调已关闭当前菜单，也会消费对应
  `MR_KEY_RELEASE`。这同时覆盖 E2E 默认短按、显式 hold、物理键和 shared/Flutter 入口。
- 平台菜单复用 `native_text_widget` 已有的 guest 帧镜像：菜单帧上屏时不污染镜像，
  菜单激活期间 guest 后台 draw 继续更新镜像，选择或取消后重推最新 guest 帧。这样
  最后一次 `engine.key('ENTER', 1_000)` 会收到真实 draw，测试中的 TODO 和随后 20 秒
  等待保持原样，不需要 `waitForDraw: false` 或其它兜底。

### PPM 与目标用例验证

2026-08-06 修复后产物 `/tmp/skyengine-e2e-Pl7dfg`：

| PPM | 画面 | SHA-256 | 关键像素 |
| --- | --- | --- | --- |
| `menu.ppm` | 游戏主菜单 | `1c91a047d444affe4ccd93eabdc59891da8f29cfd77c65870e16e43b13b8609f` | `(40,13)=[72,144,248]` |
| `screen.ppm` | 第一层“游戏设置”菜单 | `d31b8dd4c4a47502864723982461cb7160c533c3b5db121651b56b60e5dd8012` | `(144,50)=[0,0,248]` |
| `setting.ppm` | 第二层“棋子选择”菜单 | `811cce9d11206f6fcfab23eb389643253045be342dccbfd8a525922b2df951d0` | `(144,50)=[0,0,248]` |

`pnpm vitest run test/e2e/white/settings.test.ts --reporter=verbose` 已通过（1/1，
约 21.5 秒）。未使用 xvfb，也未开启全量 trace。

选择后的最终可见帧 `/tmp/skyengine-e2e-XDuS0j/screen.ppm` SHA-256 为
`19f81b07328dd9d8659aba9d48fd85cfe3e287e52e6fc27aa6b2adb1c88a4047`：
`(165,221)=[0,144,192]`，而平台菜单位置 `(144,50)=[120,124,200]`，证明关闭
菜单后已经恢复 guest 主菜单，不再停留在 `[0,0,248]` 的平台菜单画面。

### 兼容审计结果

- clean shared-only 构建通过：`[100%] Built target skyengine-shared`，菜单模块没有
  引入 SDL/main 未解析依赖。本机没有 `emcc`，未执行 Wasm 构建。
- 旧版 `white/settings.test.ts` 与 `white/capture-menu.test.ts` 均通过，覆盖默认短按、
  选定后恢复画面和显式 hold 输入。
- `gtdgdq/menu.test.ts`、`gtxzj/boot-to-title.test.ts`、`cookie/run-mrp.test.ts`
  回归通过；合计 5 个测试文件、6 个用例全部通过。
- runtime destroy 会清除 active 菜单及已接管但尚未到达的 release，避免同进程
  destroy/init 后继承平台 UI 状态。

### 保存后继续操作的新增用例

用户将 `white/settings.test.ts` 扩展为：保存棋子设置后确认回到 guest 菜单，再连续
发送三个 `UP`。最新用例稳定在第一个 `UP` 失败：`ERR wait_draw_timeout current=8
target>8`。窄事件日志证明该按键的 `MR_KEY_PRESS/RELEASE` 均已越过平台菜单过滤器，
问题不在 E2E 回执。

进一步反汇编得到：

- `0xE82610` 保存选项后调用 `0xE8406C`；后者通过 host table `+0x114`，即
  table[69] `mr_dialogCreate`，创建 `MR_DIALOG_OK(0)` 的“提示 / 设置成功”对话框；
- dialog 构造器在调用平台前已通过 `0xE84F94` 把事件处理器压入 guest 栈；
- 当前 `native_dialogCreate` 固定返回 `MR_FAILED`，guest 失败分支只释放 dialog 对象，
  没有调用 `0xE84D50` 弹出事件层；后续 `UP` 因此进入悬空 dialog handler，不会到达
  主菜单处理器 `0xE81DC0`，所以没有 draw；
- SDK `mrc_base.h` 和 MTK/SPL 两份平台源码都定义 type 0 为带“确定”键的模态框，
  正确实现会要求用户确认；而新增测试要求不确认提示框、直接操作底层菜单。两种行为
  不能同时满足，且自动确认/失败后合成取消事件会违反本任务“不要兜底逻辑”的约束。

### 2026-08-06：保存成功提示与父菜单恢复闭环

用户允许按真实平台语义微调测试后，最终没有自动确认或失败兜底，而是完整实现了
`mr_dialog*` 和嵌套菜单 handle 生命周期：

- `native_dialogCreate/Release/Refresh` 复用已有 `native_text_widget`。SDK 明确允许
  对话框与文本框使用相同呈现；保存后显示黑底绿字的“提示 / 设置成功”页面，测试
  通过左软键产生 `MR_DIALOG_EVENT, MR_DIALOG_KEY_OK` 显式确认。
- `native_text_widget_refresh` 新增 type 参数，`mr_dialogRefresh` 按契约支持 `-1`
  保持原按钮类型，`mr_textRefresh` 固定传 `-1`。
- 文本窗口像 native menu 一样记录自己接管的 PRESS；guest 在 OK 回调中立即释放
  窗口后，对应 RELEASE 仍由平台消费。若 PRESS 在窗口创建前已经交给 guest，则
  RELEASE 也继续交给 guest，避免产生半对按键。

确认 dialog 后首次实现仍无法操作的原因不是 dialog：精确 PC 观察点显示：

- `0xE8402C` 收到 `MR_DIALOG_EVENT(OK)`；
- `0xE82668` 成功回调、`0xE84E04(1)` 和 `0xE84D50` 均执行；
- 随后的 `UP` 已到统一事件分发器 `0xE84EE4`，但当前对象是第一层 native
  “游戏设置”菜单，其 handler `0xE84168` 只处理 `MR_MENU_SELECT/RETURN`。

white 的栈顺序实际是“主菜单 → 游戏设置 native menu → 棋子选择 native menu →
成功 dialog”。OK 回调只析构 dialog 和棋子选择菜单，随后通过父菜单 lifecycle
`action 2` 调 table[68] `mr_menuRefresh(parentHandle)`。此前 DSM 只保存一份全局菜单，
第二层 `mr_menuCreate` 会释放并覆盖第一层数据；`mr_menuRefresh` 又只是空成功，因此
屏幕露出 guest 镜像，但事件栈仍停在不可见的父 native menu，形成画面/输入错位。

最终通用修复：

- DSM 用链表按 handle 独立保存每个菜单的 title/items；创建子菜单不再销毁父菜单。
- `mr_menuRelease(handle)` 只释放指定菜单，runtime teardown 统一释放剩余 handle。
- `mr_menuRefresh(handle)` 用该 handle 的持久数据重新委托平台呈现，符合子窗口关闭后
  恢复父窗口的真实生命周期。
- 最新测试流程为：保存 → 验证成功 dialog → 左软键确认 → 验证父“游戏设置”菜单
  恢复 → 右软键取消父菜单 → 保留原来的三个 `UP` → 验证回到主菜单第一项。

PPM 证据（`/tmp/skyengine-e2e-tep1J8`）：

- `setting-saved.ppm`：`767787bff9fe94d5aa309d50e3613dc14b86bd0ac3ccfa10f219597291bab561`；
- `setting-parent.ppm` 与首次 `setting-1.ppm` 逐字节相同，SHA-256 均为
  `d31b8dd4c4a47502864723982461cb7160c533c3b5db121651b56b60e5dd8012`；
- 最终 `menu-first.ppm` 与启动 `menu.ppm` 逐字节相同，SHA-256 均为
  `1c91a047d444affe4ccd93eabdc59891da8f29cfd77c65870e16e43b13b8609f`。

验证结果：

- `white/settings.test.ts` 通过（1/1，约 2.56 秒）；
- `white/settings`、`white/capture-menu`、`gtdgdq/menu`、`gtxzj/boot-to-title`、
  `cookie/run-mrp` 合计 5 个文件、6 个用例全部通过；
- `build-shared-only` 的 `skyengine-shared` 完整重编译通过，`nm -u` 未发现 SDL、
  E2E 通知、native menu 或 native text widget 未解析符号。

### 最终 handle 契约审计

- 平台菜单不再生成与 DSM 无关的第二套 handle；活动层直接持有 guest 可见 handle。
- 对正在显示的同一 handle 调用 `mr_menuRefresh` 会替换文本并保留当前焦点；菜单项
  变少时只把焦点夹到最后一个有效项。`mr_menuRelease` 会按 handle 关闭活动层。
- runtime teardown 通过专用 `dsm_menu_release_all` 释放全部菜单，不再借用公开的无效
  handle `0`；字库、显示尺寸或首帧分配失败会明确返回失败，不显示空白菜单兜底。

最终目标用例产物为 `/tmp/skyengine-e2e-bXg4Mn`。`setting-parent.ppm` 与
`setting-1.ppm` 逐字节相同，`menu-first.ppm` 与 `menu.ppm` 逐字节相同；哈希分别仍为
`d31b8dd4c4a47502864723982461cb7160c533c3b5db121651b56b60e5dd8012` 和
`1c91a047d444affe4ccd93eabdc59891da8f29cfd77c65870e16e43b13b8609f`。

最终复跑结果：目标用例 1/1 通过，兼容组第二次完整运行 5 文件/6 用例通过；
`cookie/run-mrp.test.ts` 还单独复跑 2/2 通过。普通构建与 shared-only 构建均通过。

### 2026-08-06：消除平台层切换时的主菜单闪帧

原实现的菜单选择顺序为“关闭平台菜单并恢复 guest 镜像 → 投递
`MR_MENU_SELECT` → guest 回调创建下一层平台 UI”。因此 `setting-1` 到
`setting-1-1`、`setting-1-1` 到 `setting-saved` 之间都会真实提交一张主菜单帧。

新增测试先记录按键前后的 draw count，再通过 `SCREEN_DRAW` 检查这段范围内的每张帧。
旧实现稳定在第一张过渡帧失败：`/tmp/skyengine-e2e-zCUNW7` 中
`setting-child-transition-6.ppm` 的 SHA-256 为
`19f81b07328dd9d8659aba9d48fd85cfe3e287e52e6fc27aa6b2adb1c88a4047`，与主菜单选中
“游戏设置”时的帧完全相同。

通用修复是在平台 UI 事件回调外围建立可嵌套的切换事务：

- 菜单选择和 dialog 按钮回调开始前进入事务，回调返回后退出。
- 事务期间关闭 overlay 只登记待恢复，不立即提交 guest 镜像。
- guest 在回调中产生的背景 draw 仍更新镜像，但不会在下一层 overlay 创建前上屏。
- 回调结束后若已有新菜单或 dialog，直接保留新平台层；只有没有后继平台层时才恢复
  最新 guest 镜像。该逻辑不依赖应用名、菜单文本或地址。

最终产物 `/tmp/skyengine-e2e-oAeeFW` 中每段切换都只有一张目标帧：

- `setting-child-transition-6.ppm`：`811cce9d11206f6fcfab23eb389643253045be342dccbfd8a525922b2df951d0`；
- `setting-saved-transition-7.ppm`：`767787bff9fe94d5aa309d50e3613dc14b86bd0ac3ccfa10f219597291bab561`；
- `setting-parent-transition-8.ppm`：`d31b8dd4c4a47502864723982461cb7160c533c3b5db121651b56b60e5dd8012`。

目标用例通过（1/1，约 2.58 秒）；兼容组 5 文件/6 用例通过；普通构建和
shared-only 构建均通过。

### 2026-08-06：平台菜单软键标签

平台菜单底部新增 26px 软键栏，先清除可能延伸到底部的选项背景，再绘制分隔线；
左下角使用 UCS2 `确定`，右下角使用 UCS2 `返回`。文字复用 dialog/text widget 的
平台字库和 RGB565 绿色，不引入另一套字体或应用特判。

`white/settings.test.ts` 会在父、子菜单画面的 `y=299..314` 范围检查左右文字区域。
最终产物 `/tmp/skyengine-e2e-araAf3/setting-1.ppm` 的实际绿色字形统计为：

- `确定`：包围盒 `(4,299)-(34,314)`，145 个绿色像素；
- `返回`：包围盒 `(204,299)-(233,313)`，141 个绿色像素。

加入标签后的父菜单帧 SHA-256 为
`8cb7c7c5bd62dae601da7bdefb4f1d1d16505977df2ebf6ac4caa69eae9d2d00`，子菜单帧为
`e54eedc83be0e1bbba9fe23b29144353783bdaa722635e5e6a5ff518a2bfc4c8`；父菜单恢复帧
仍与首次父菜单逐字节相同，无闪帧检查继续通过。最终兼容组为 5 文件/6 用例通过，
普通构建与 shared-only 构建通过。

### 2026-08-07：设置菜单触摸支持（诊断阶段）

目标用例的既有键盘流程仍通过（1/1，约 2.27 秒）。在同一流程打开第一层平台
“游戏设置”菜单后，执行 `CLICK 120 48` 的修复前基线为 draw count `5 -> 5`，
最终返回 `ERR wait_draw_timeout current=5 target>5`。这排除了测试启动、菜单创建和
画面等待问题，直接证明触摸没有触发任何菜单重绘或选择。

事件链证据如下：

- E2E `CLICK` 已生成带完整坐标的 SDL mouse down/up；`main.c` 将其原样转换为
  `event(MR_MOUSE_DOWN/UP, x, y)`，无需新增测试协议。
- `skyengine_runtime_event` 调 `native_modal_menu_filter_event` 时只传 `code,p0`，
  因而菜单只能取得 x；当前过滤器又对三个 `MR_MOUSE_*` 分支直接返回 1，y 被丢弃且
  事件只被消费、不产生动作。这是可见菜单只能用键盘、触摸完全无响应的直接原因。
- 平台参考实现 `mrp_localui.cpp` 将 `VcpListMenu::m_signalItemTapped` 连接到
  `onSelectItem`，完整点按后发送 `MR_MENU_SELECT(index)`；底部返回工具栏发送
  `MR_MENU_RETURN`。所以 raw mouse 不能穿透到 guest，而应在平台菜单层转换事件。
- white.ext 的既有反汇编显示 `0xE84168` 只处理 `MR_MENU_SELECT/RETURN`；
  `0xE842BC..0xE842C0` 的 `mr_menuShow` veneer 也不等待 raw touch。该证据与平台
  源码相互印证，故障不在 guest 菜单 handler。

最小通用改动限定为：把完整 `x/y` 交给 `native_modal_menu`，按当前渲染几何命中
菜单项和底部确定/返回区域，并只在 down/up 命中同一目标时提交选择。需要记录 down
所有权，避免“打开菜单的 guest DOWN 对应的 UP”误选新菜单，也避免选择回调同步创建
子菜单后旧事件穿透。此次不扩展 SDL finger、多点触控或 dialog 触摸，它们不是当前
`MR_MOUSE_*` 菜单故障的必要改动面。未启用 trace，未使用 xvfb。

#### 实现与验证

- `native_modal_menu_filter_event` 接收完整 `p0=x,p1=y`。菜单项命中直接复用绘制
  常量：第 i 行是 `[38 + 22*i, 60 + 22*i)`；软键栏从动态屏高减 26 得到，左右
  半区分别对应确定和返回，没有应用名、菜单文字或包名分支。
- 平台层在 `MR_MOUSE_DOWN` 保存目标，命中菜单项时只更新焦点；仅当
  `MR_MOUSE_UP` 仍命中同一目标时才发送 `MR_MENU_SELECT/RETURN`。UP 前先清捕获，
  防止同步创建的子菜单继承旧手势；中途 refresh 会取消旧目标但继续消费其 UP。
- 新增独立 E2E 用例保留原键盘全流程。测试先把焦点移到第二项，再触摸第一项，随后
  触摸子菜单“返回”和父菜单“确定”，证明实现使用触点 index 而非把任意点击映射为
  当前焦点 ENTER，并覆盖嵌套 handle 恢复。

目标用例 `pnpm vitest run test/e2e/white/settings.test.ts --retry=0
--reporter=verbose` 为 2/2 通过（约 4.15 秒）。产物
`/tmp/skyengine-e2e-U5e2Rx` 的 PPM 证据：

- 父菜单、触摸返回后的父菜单 SHA-256 均为
  `8cb7c7c5bd62dae601da7bdefb4f1d1d16505977df2ebf6ac4caa69eae9d2d00`，逐字节相同；
- 子菜单、触摸确定后重开的子菜单 SHA-256 均为
  `e54eedc83be0e1bbba9fe23b29144353783bdaa722635e5e6a5ff518a2bfc4c8`，逐字节相同；
- 选项触摸只提交父菜单和子菜单两帧，返回/确定各只提交目标层一帧；所有过渡帧均未
  出现 guest 主菜单标题像素。修复前同一点为 draw `5 -> 5`，修复后探针为
  `6 -> 8`，父子帧相差 1991 个像素。

最终兼容审计：

- `pnpm test:e2e`：36 个测试文件、63 个用例全部通过；套件中 `gtlbd/text` 曾重试
  一次，随后单独用 `--retry=0` 运行 1/1 通过（约 11.09 秒）。
- `cmake --build build --target skyengine` 与从空目录配置、构建的
  `build-shared-only`/`skyengine-shared` 均通过；共享库未发现 SDL、E2E、
  native menu/text widget 未解析符号。
- `pnpm exec tsc --noEmit` 与 `git diff --check` 通过。全过程未使用 xvfb，也未开启
  大量 trace。
