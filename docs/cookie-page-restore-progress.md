# cookie 退出子mrp后页面恢复研究进度

## 当前状态

- ✅ 子mrp能正常启动
- ✅ 退出返回cookie（不是dsm_gm）
- ✅ 无开屏动画（`_mr_param='_RL'` 正确传递）
- ⚠️ 返回cookie首页，不是文件管理页面

## 分析进度

### logo.ext 反汇编结论

logo.ext 是一个 **cfunction.ext 风格的插件管理器/wrapper**：
- `mrc_init(code=0)`: 初始化 + 加载子插件(game.ext等)
- code=1(event): 透传事件给所有已注册子插件
- code=2(timer): 转发定时器
- **logo.ext 本身不解释5001命令**，只做透传

5001命令处理路径：
```
start.mr → _strCom(801, pack("iii",5001,arm_ptr,3), 1)
         → logo.ext code=1
         → logo.ext 透传 {5001, arm_ptr, 3} 给 game.ext 的 event handler
```

### SUBV 验证结果

退出返回cookie时 SUBV 日志确认：
```
[SUBV] str='_RL' len=3 ext=0x5c6f246440
[SUBV] arm_addr=0x345E84
```
`_RL` 被正确拷贝到ARM内存，ARM ext 收到有效的ARM地址。

### CASE801 验证结果

```
[CASE801] code=1 data=[89 13 00 00 84 5e 34 00 03 00 00 00]
           5001(le)    arm_ptr       len=3
[CASE801] code=1 ret=1 output_len=0
```
ARM ext 正确接收并处理了5001命令，返回MR_SUCCESS。

### 磁盘文件分析

退出返回cookie时只写了 `fpd.sav`（首次运行标记），没写页面状态文件。
- config.sav (JSSf格式): 全局配置，无页面状态
- mdsm.lst (MLSI格式): 应用列表索引
- plugins/: 子插件mrp包，时间戳未变
- gdfwd/: 子mrp数据目录，为空

cookie的页面状态（文件管理列表位置）不在磁盘上，在ARM ext运行时内存中。

### 问题根因

退出返回cookie走完整重建路径：
```
mr_timer RESTART → mr_stop() → mr_stop_ex(TRUE) → native_ext_reset() → arm_ext_unload()
→ _mr_intra_start() → dofile('start.mr') → _mr_c_load() → arm_ext_load() (全新ArmExtModule)
→ mrc_init(code=0) → game.ext初始化为默认状态(首页)
→ code=1 收到5001通知"从子应用返回"
```

game.ext 收到5001后应该切换到文件管理页，但它可能需要从某个**全局变量或运行时状态**恢复页面位置，这些在mr_stop时丢失了。

### game.ext 反汇编结论

**game.ext 完全不处理 5001 (0x1389) 命令。** 在整个 269KB 二进制中，5001 以任何编码形式都不存在。
5001 只是 logo.ext/start.mr 的通用参数转发协议，game.ext 忽略它。

game.ext 的页面恢复依赖 `mrc_init` 读取磁盘状态文件恢复页面：
- `ckrun.dat`、`mrparam.bak`、`reload.flag`、`l1XrunState.sav`（字符串在 game.ext 中引用）

### 磁盘状态文件检查

cookie 正常退出（回到 dsm_gm）后检查文件变化：
- 变化的文件：`fpd.sav`、`localdir.sav`、`nettype.sav`、`rollmsg.dat`
- **`ckrun.dat` 等页面状态文件完全不存在**
- 说明 cookie 在当前模拟器环境下没有创建页面状态文件

可能原因：
1. cookie 需要特定条件才创建（如网络连接成功后同步状态）
2. cookie 的页面恢复不依赖磁盘文件，而依赖运行时内存

### 最终根因分析

真机和模拟器的关键差异在于 ARM ext 内存处理：

**真机**：
- `mr_stop_ex` 调 `mr_mem_free(LG_mem_base)` 释放 Mythroad 堆
- 但堆在进程地址空间中仍存在（标记为 free，数据未清零）
- `_mr_intra_start` → `_mr_mem_init` 重新初始化同一块堆
- game.ext 代码重新加载，但**之前 malloc 的数据可能还在堆中**
- `mrc_init` 通过 exRam 扫描或内存残留恢复页面状态

**模拟器**：
- `mr_stop_ex` → `native_ext_reset()` → `arm_ext_unload()` 释放 Unicorn 的 16MB 内存块
- `arm_ext_load` 创建全新 `ArmExtModule`（全新 mem，zero-fill）
- game.ext 的运行时状态被完全清除
- `mrc_init` 找不到残留状态，走默认首页

### 网页模拟器日志对比分析（重要突破）

通过对比网页模拟器(vmrp.gddhy.net)的日志，发现了 `fm.sav` 文件：

**网页模拟器流程**：
1. cookie 启动子mrp前：`mr_open(mythroad/fm.sav, 10)` **写** fm.sav（保存页面状态）
2. 退出返回 cookie 时：`mr_open(mythroad/fm.sav, 1)` **读** fm.sav（恢复页面状态）
3. 读后：`mr_remove(mythroad/fm.sav)` **删除** fm.sav（一次性消费）

**OHOS 模拟器行为**：
- `fm.sav` 存在（13字节），退出返回时被重写（时间戳变化）
- 内容变化：退出前末字节 `0x1F(31)` → 退出后 `0x16(22)`（可能是列表选中项）
- 但 cookie 仍显示首页，说明 fm.sav 的内容不足以恢复"当前在文件管理页"状态

**fm.sav 内容分析**（13字节）：
```
00 00 00 01  00 00 00 00  01 00 00 00  1F/16
              前12字节不变        末字节=选中项索引
```

### 真正的页面恢复机制

页面恢复不依赖磁盘文件（fm.sav 只记录列表选中项），而依赖：
1. **`_mr_param` 值**：cookie 的 start.mr 检查 `_mr_param` 非空时发 5001 命令
2. **ARM ext 的 mrc_init 内部状态**：game.ext 在初始化时根据某些条件决定初始页面
3. 网页模拟器能恢复是因为它的 ARM ext 内存模型和真机一致（共享地址空间）

### game.ext mrc_init 深入反汇编结论

反汇编确认 game.ext 的页面恢复机制：

1. **`_RL` 通过 `table[138]` 读取**（`sb+0xF7A8` 桥接指针，地址 0x1B338）
2. **`fm.sav` 在 FM 视图函数中读写**（地址 0xBD0E-0xC5E4，`fm_view.c` 模块）
3. **`reload.flag`/`mrparam.bak`** 在重载检测函数中检查（地址 0x19D44）
   - 如果 `reload.flag` 存在 → 执行重载
   - 否则使用 `mrparam.bak`
   - 两者都不存在 → 走默认初始化

**设备上 `reload.flag` 和 `mrparam.bak` 都不存在**——game.ext 走默认初始化。

### 真正的根因：wrapper 模态快照丢失

页面恢复的真正机制是 **wrapper（logo.ext）的前台分发表**（RW 区 `+0xE0`, 长度 `0xD0`）：

- **cookie 启动子mrp前**：wrapper 的 suspend 把前台分发表切到子mrp
- **退出返回 cookie 时**：wrapper 的 resume 恢复前台分发表 → 事件路由回到文件管理页

模拟器的 `arm_ext_save_modal_fg_snapshot`/`arm_ext_restore_modal_fg_snapshot` 实现了这个机制。但：

- **RESTART 场景下** `mr_stop()` → `arm_ext_unload()` 销毁整个 `ArmExtModule`（含 `modal_fg_snapshot`）
- 新 module（`arm_ext_load`）没有快照，前台分发表为默认值（首页）
- 真机上 wrapper 的 RW 区在 RESTART 后仍存在（内存未清零），分发表保留

**不能简单拷贝快照到新 module**——分发表中的函数指针/helper 地址在新 mem 中不同，直接拷贝会崩溃。

### 最终结论

页面恢复需要 wrapper 的 RW 分发表在 RESTART 后正确恢复。这是一个架构级问题：
- 方案1：RESTART 时不销毁 module，只重新执行 mrc_init（需要精确的 ext 生命周期管理）
- 方案2：保存 wrapper RW 区的分发表，在新 module 中重新定位后恢复
- 方案3：暂不修复，当前功能（启动+退出+无动画）已满足基本使用需求
