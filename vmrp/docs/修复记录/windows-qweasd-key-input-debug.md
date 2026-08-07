# Windows QWEASD 按键输入修复记录

## 2026-08-07 初始定位

### 现象

- Windows 桌面版中物理键 `Q/W/E/A/S/D` 没有产生预期的软键或方向键响应。
- 本轮目标是修复物理键盘输入，不改变 Mythroad 的 `MR_KEY_*` ABI，也不调整自动点击时序。

### 已确认的事件链

1. SDL 主循环在 `src/main.c` 中读取 `SDL_KEYDOWN/SDL_KEYUP`。
2. `dispatch_key_down()` / `dispatch_key_up()` 用一个宿主按键锁保证 press/release 配对。
3. `keyEvent()` 已包含以下 `SDL_Keycode` 映射：
   - `W/S/A/D` -> `MR_KEY_UP/DOWN/LEFT/RIGHT`
   - `Q/E` -> `MR_KEY_SOFTLEFT/SOFTRIGHT`
4. 因此问题不是 Mythroad 键码枚举或映射分支缺失；当前需要确认 Windows SDL 事件给出的
   `keysym.sym` 是否与映射使用的字符 keycode 一致，以及按键锁是否按同一标识配对。

### 待验证假设

- Windows 的键盘布局会影响 `keysym.sym`，而这六个模拟器控制键表达的是物理键位，应该按
  `keysym.scancode` 识别。
- 如果按下和释放路径使用不同的规范化方式，`isKeyDown` 会残留并阻塞后续按键；修复必须让
  press/release 使用同一个规范化键标识。

### 计划验证

- 在现有 Windows 构建上向 SDL 窗口投递原生 `WM_KEYDOWN/WM_KEYUP`，记录真实输入结果。
- 补充不依赖具体 MRP 应用的键盘映射单元回归，覆盖 Q/W/E/A/S/D 和原有方向键、软键别名。
- 构建 Windows `skyengine`，再运行至少一个使用键盘导航的 Vitest e2e 用例。

## 2026-08-07 根因与修复

### Windows 实测与反汇编结论

- 项目使用的 SDL 2.28.5 在当前简体中文 QWERTY 布局下会把六个物理键正确转换为
  小写 `SDLK_q/w/e/a/s/d`；Shift 和 CapsLock 不会把字母 `sym` 改成大写。因此增加
  大写分支或 `tolower()` 不能修复问题。
- Debug 对象反汇编确认旧版 `dispatch_key_down()` 在调用映射前先写 `isKeyDown`：
  任意 Shift/Ctrl/Alt 等未映射键都会占据单键锁。以 `Shift+W` 为例，Shift KEYDOWN
  先占锁，W KEYDOWN/KEYUP 随后都被拒绝，所以用户看到 QWEASD 没反应。
- `keysym.sym` 是布局相关的逻辑键，固定游戏控制位还会在非 QWERTY Windows 布局下
  失效；`keysym.scancode` 才表示物理键位。

### 实现

- 新增 `src/keyboard_input.c` 和 `src/include/keyboard_input.h`，集中维护 SDL 到
  `MR_KEY_*` 的既有映射以及单键锁。
- Windows 真实物理事件按 `SDL_SCANCODE_Q/W/E/A/S/D` 规范化为固定控制键位；方向键、
  数字、回车和其它别名继续保持原来的 `keysym.sym` 语义。
- `windowID == E2E_KEY_WINDOW_ID` 的事件明确跳过 scancode 规范化，因为 E2E 协议会把
  命令 token 存在 `keysym.scancode`。测试覆盖 token 值恰好等于六个物理 scancode
  的碰撞场景，避免 Linux E2E 随命令序号偶发误映射。
- 单键锁现在只接受能转换成 `MR_KEY_*` 的按键。Shift/Ctrl/Alt 等未映射键仍不会送入
  guest，但也不会阻塞随后按下的 QWEASD；已映射键的单键手机语义和自动重复过滤不变。
- 未改 `MR_KEY_*` 枚举、事件码或 Mythroad ABI；没有应用名、MRP 路径或样本特判。

## 2026-08-07 验证记录

### 单元测试

Windows/MSVC Debug：

```powershell
cmake --build build --config Debug --target skyengine-keyboard-input-test
ctest --test-dir build -C Debug --output-on-failure -R skyengine-keyboard-input
```

结果：`skyengine-keyboard-input` 通过。覆盖六个物理 scancode、故意错误的 `sym`、
六个 E2E token 碰撞值、方向键/括号/回车别名，以及未映射 Shift 不占单键锁。

同一测试用 WSL Ubuntu 的 GCC 11 以 `-Wall -Wextra -Werror` 直接编译并通过。完整的
WSL CMake 配置未能运行：Windows 工作树中的 `third_party/unicorn/qemu/configure`
带 CRLF，`dash` 在生成 `config-host.h` 前即报错；这发生在本次源码进入编译之前，
Windows MSVC Debug/Release 的完整 `skyengine` 构建不受影响。

现有 Vitest E2E 不能驱动 Windows 可执行文件：`src/e2e_control.c` 在 `_WIN32` 下是
空实现，不会建立 `SKYENGINE_E2E_SOCKET`。终审尝试 `white/settings` 和
`wbrw/input-text`，均在进入业务断言前等待 socket 超时。因此本轮用 CTest 覆盖纯映射
与锁存契约，并用 Windows 原生 `WM_KEYDOWN/WM_KEYUP` + PPM 覆盖实际 SDL/guest/UI
链路；没有把上述 Vitest 超时记作通过。

### Windows 原生事件与 PPM

- 使用带正确 scan-code lParam 的 `WM_KEYDOWN/WM_KEYUP` 向 SDL 窗口投递物理事件。
- 普通 Q/W/E/A/S/D 和按住 Shift 后的 Q/W/E/A/S/D 共得到 24 次成对 guest 投递：
  每组分别映射为 `MR_KEY_SOFTLEFT/UP/SOFTRIGHT/LEFT/DOWN/RIGHT` 的 press/release。
- 单独执行 `Shift+S` 导航 `white.mrp`：
  - 输入前 PPM SHA-256：
    `1C91A047D444AFFE4CCD93EABDC59891DA8F29CFD77C65870E16E43B13B8609F`
  - 输入后 PPM SHA-256：
    `3F35076644B9C1538F011FF6CAC30F49F98BC3E3C2F1EE2F65D1BFDDC7EC35BD`
  - PPM 字节差异：13,620；日志确认 guest 收到且只收到配对的 `MR_KEY_DOWN`。
- 去除临时日志后对 Release 可执行文件重复同一烟测，两个哈希和 13,620 字节差异保持
  一致，进程退出码为 0，stderr 不含 `KEY_DIAG`。最终复现产物位于：
  `C:/Users/CHENQI~1/AppData/Local/Temp/vmrp-windows-release-final-audit-20260807`。
- 直接检查转换后的两张 PPM：高亮项从“开始游戏”移动到“游戏介绍”，画面尺寸和背景
  保持正常，排除了无关初始化帧或窗口抖动造成哈希变化的可能。

临时 `VMRP_KEY_DIAG` 日志在确认上述结果后已移除，避免增加日常 trace 量。

### optwar.mrp 六键画面回归

在 `build/Release` 目录按用户给出的相对路径实际启动：

```powershell
.\skyengine.exe .\mythroad\optwar.mrp
```

测试向 SDL 窗口依次发送带 Windows 物理 scan code 的完整
`WM_KEYDOWN/WM_KEYUP`（按下与释放间隔 100 ms），并在每步后复制模拟器输出的
240x320 PPM。这样同时覆盖 Windows 消息、SDL scancode、VM 按键映射和 MRP 界面，
而不是只验证宿主侧映射函数。

| 物理键 | scan code | 可识别的画面结果 |
| --- | ---: | --- |
| E | `0x12` | 在“是否开启游戏音乐？”页选择右软键“否”，进入《太平洋战争 1941》主菜单；战斗菜单中再次按 E，中央菜单消失并恢复实时战斗。 |
| D | `0x20` | 第一次关闭顶部广告，第二次把主菜单选择从“开始游戏”移到“自由选关”。 |
| A | `0x1E` | 把主菜单选择从“自由选关”移回“开始游戏”；恢复帧与 D 前帧 SHA-256 完全相同。 |
| Q | `0x10` | 以左软键确认“开始游戏”，进入“偷袭珍珠港”关卡介绍；进入战斗后再次按 Q，打开游戏内菜单。 |
| S | `0x1F` | 把游戏内菜单高亮从“火力全开”下移到“购买生命”，没有确认购买。 |
| W | `0x11` | 把高亮从“购买生命”移回“火力全开”；恢复帧与 Q 打开菜单后的基准帧逐像素相同。 |

关键画面哈希：

- 启动提示：`2D2A58C104441550632FB21770797EFAC60E01F84E9BA99085EF6EA04E2E903E`
- E 后主菜单：`EAFEE6FD8E0B8E4E1F427D792582455137C42D7F86008A459D7CA3B1F6160357`
- D 后“自由选关”：`495CCA5CE88CF395F11A9A045006F2DB9EAB668DE2117384B5FBB50416440AE6`
- A 后“开始游戏”：`FC354F1AAAEB8110C905B7BBE54888CA77F45DC0608CF077133529BC2AD257C6`
- Q 后关卡介绍：`4C2051E4AB61445FDD1BF0BDA64ED23D069B4C128BEEF811439EE14C087E1C34`
- Q 打开战斗菜单、S 后、W 后：分别为
  `17D9A7156CD4C90CF4F6CE2DD4BCDD263EB7EFD8D9A9F4034770B8F064B75479`、
  `FB46F90F06CBB1928DAAA3FD529A6AF8FB1254C5CA7C6A0A5DFF213434055114`、
  `17D9A7156CD4C90CF4F6CE2DD4BCDD263EB7EFD8D9A9F4034770B8F064B75479`。
- E 关闭菜单后的实时战斗帧：
  `509A6B9AABFD36D814AA7729107CCFE4F48C82805223D90AB27B5E817F85695F`。

Q 打开菜单与 W 恢复菜单后的两张 PPM 在全部 76,800 个像素上完全相同。S/W
两帧只有菜单矩形 `x=39..200, y=88..247` 内的 5,925 个像素不同，菜单区域外没有
差异，因此高亮变化不是实时背景、初始化帧或并发写入造成的假阳性。抓取过程中对 PPM
先复制再解码，遇到写入中的不完整文件会重试，不把残缺帧纳入结果。

全部 PPM 和便于目视复核的 PNG 位于：
`C:/Users/chenqiancheng/AppData/Local/Temp/vmrp-optwar-visual-20260807-134200`。
`stderr.log` 仅含正常初始化记录。最后向同一 SDL 窗口发送 `WM_CLOSE`，PID 39808
在一秒内退出且系统中不再存在；该进程由先前独立 PowerShell 会话启动，本次关闭时未取得
可用退出码，因此不将退出码记录为 0。本节是 Windows 原生消息与实际画面回归，没有声称
运行 Windows Vitest。
