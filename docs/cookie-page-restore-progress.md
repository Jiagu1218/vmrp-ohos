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

### 后续方向

1. **反汇编 game.ext 的 event handler**：找到5001的处理逻辑，看它需要什么状态来恢复文件管理页
2. **对比真机**：真机上也走同样的mr_stop+_mr_intra_start路径，但能恢复——差异可能在ARM ext对宿主环境的探测
3. **检查game.ext的mrc_init**：看它初始化时是否通过_strCom/readFile查询某些状态
4. **考虑wrapper层面的状态保留**：logo.ext作为wrapper，可能在mrc_init时通过exRam扫描恢复子插件状态
