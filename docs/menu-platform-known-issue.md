# 平台菜单(menu)实现 + 已知问题

## 已实现

平台菜单 API(mr_menuCreate/SetItem/Show/Release/Refresh,table[62-68])通过
OHOS 构建补丁注入实现,参考 editCreate 架构:

- vmrp 侧(`ohos_src/native_menu_state.c`)只存菜单数据 + active 标记
- 前端 ArkTS 弹原生菜单 Dialog(List 组件渲染,支持触屏点选)
- 用户选择 → submitMenu(index) → 投递 MR_MENU_SELECT(4) 事件
- 用户取消 → cancelMenu → 投递 MR_MENU_RETURN(5) 事件

## 已知问题:二级菜单 timer owner 卡死

**现象**:一级菜单(如"游戏设置")正常工作。但当应用在 menu 选择事件处理中
**再次调 menuShow 创建二级菜单**(如选"游戏难度"后弹出难度选择)时,二级菜单
能正常弹出,但关闭后(选择或取消)游戏画面卡住。

**诊断结论**:
- TimerLoop 持续运行(engine running=true)
- worker 线程持续跑 timer()
- 但 screen_dirty 永远为 false(ARM 代码不写屏幕)
- 即 timer() 派发到了不绘制画面的 timer owner

**根因**:二级菜单的 menuCreate/menuSetItem 在 `event(4,N,0)` 内部执行(ARM 代码
处理一级菜单选择时创建二级菜单)。这些调用注册了 nested module、改变了 ARM 内存
状态。后续 `event(5,0,0)`(取消)或 `event(4,N,0)`(选择)处理时,arm_ext_call
的 timer dispatch 逻辑(`capture_timer_dispatches` + timer owner 上下文管理)基于
这些改变的状态走错路径,把 timer owner 设到不绘制的模块。

**已尝试的缓解措施**:
1. `arm_ext_keep_host_tick_alive` 在 menuShow 后保持 timer 活跃 — 无效(timer
   在跑但 owner 错)
2. deferred menuShow(event 内部只设 pending,返回后 flush)— 二级菜单能弹出
   但关闭后仍卡
3. fallback timer(event 返回后补 30ms timer)— 无效

**影响范围**:仅在应用使用**平台菜单 API 且有多级菜单**时触发。大多数 MRP 游戏
使用自绘菜单(不调平台 menu API),不受影响。

**待修复方向**(需上游 vmrp 配合):
- arm_ext_call 的 timer dispatch 上下文管理需要处理"event 内部调 menuCreate
  注册 nested module"的场景
- 或:capture_timer_dispatches 在 event 执行上下文里跳过(native_menu_in_event
  标志已就绪,但 capture 在 hook_table 层,需要更深层的补丁)

## 补丁文件

| 文件 | 内容 |
|------|------|
| `ohos_src/native_menu_state.c/.h` | menu 状态管理(create/set_item/show/release + UCS2→UTF8) |
| `scripts/CMakeLists.txt` OHOS_MENU 补丁块 | 注入 aex_table[62-68] + skyengine_api menu API + arm_ext_host.h 声明 |
| `scripts/CMakeLists.txt` OHOS_TEXTWIDGET_BEAUTIFY | textCreate 美化(标题分隔线 + 软键栏加粗 + 行距) |
| `entry/src/main/cpp/vmrp_engine.h/.cpp` | menu API 函数指针 + 方法 |
| `entry/src/main/cpp/vmrp_napi.cpp` | NotifyMenuIfNeeded + submitMenu/cancelMenu NAPI |
| `entry/src/main/ets/components/EmulatorControls.ets` | MenuDialogContent 组件 |
| `entry/src/main/ets/pages/Emulator.ets` | setMenuCallback + openMenuDialog |
