# cookie 退出子mrp后页面状态不恢复 — 分析与修复

## 问题

cookie.mrp 启动子 mrp 后退出，返回到 cookie 但页面状态不恢复（重新走启动流程：
显示 logo + 发网络请求），而不是直接回到文件管理页面。真机上直接显示文件管理页面。

## 逆向分析（cookie start.mr 反编译）

通过自研 Mr 字节码反编译器（`mrdis.py`）完整反编译了 cookie.mrp 的 `start.mr`。

### start.mr 逻辑

```lua
_com(3629, 2913)                       -- cookie 专用初始化

_mr_c_load = function()
   _mr_c_buf = _strCom(601, "mrc_loader.ext")   -- 读取 mrc_loader.ext
   if _mr_c_buf then
      local ret = _strCom(800, _mr_c_buf, 0)    -- 加载 ARM ext
      if ret == 3 then                          -- 两阶段加载
         local v = _strCom(801, "", 1)
         local a, b = string.unpack("II", v)
         if a ~= 0 then return _strCom(800, {a, b}, 0) end
      end
      return -1
   end
end

sysinfo = GetSysInfo()

if _mr_c_load() == 0 then
   _strCom(801, {1, sysinfo.vmver}, 6)  -- 主机初始化
   _gc()
   _strCom(801, "", 0)                  -- 启动应用(code=0)
   if _mr_param then                    -- ★ 唯一的 _mr_param 检查
      local p_mr_param, param_len = string.subV(_mr_param)
      _strCom(801, string.pack("iii", 5001, p_mr_param, param_len), 1)
   end
else
   Exit()
end
```

### 关键发现

1. **`_mr_param` 只在最后检查一次**：`_mr_c_load` + code=6 + code=0 全部执行完后，
   如果 `_mr_param` 非空，发一个 `arm_ext_call(code=1)` 携带 5001 命令。
2. **参数通过 `arm_ext_call(code=1)` 传递**，不是通过 table[138]。
3. **`string.subV` 返回 C 指针**（宿主内存地址）和长度，通过 `string.pack("iii", 5001, ptr, len)`
   打包成 12 字节 buffer 发给 ARM ext。

## 根因：string.subV 64 位指针截断

```c
// mr_strlib.c:1040
static int str_subV(mrp_State *L) {
    char *p = (char*)mr_L_checklstring(L, 1, &l_sz);  // p 是 64 位宿主指针
    mrp_pushnumber(L, (mrp_Number)p);  // mrp_Number = int32，指针被截断！
    mrp_pushnumber(L, (mrp_Number)l);
    return 2;
}
```

- 真机（32 位 ARM）：指针 32 位，`mrp_Number` 也是 32 位 int，无截断。
- OHOS（64 位 ARM64）：Lua 字符串在宿主内存，指针 64 位，截断为 32 位后值错误。
- ARM ext（Unicorn）通过截断的 ptr 访问字符串失败 → 收不到 `_mr_param='_RL'`
  → 不知道"从子应用返回" → 重新走启动流程。

### 影响范围

所有使用 `string.subV` 返回 C 指针并传递给 ARM ext 的场景都受影响。
不仅限于 cookie，任何 MRP 应用通过 `_strCom(801, pack(...,ptr,...), code)` 传指针都有问题。

## 修复方案

`string.subV` 返回的指针在模拟器中需要是 **ARM 可见的地址**。

方案：`string.subV` 把 Lua 字符串内容拷贝到 Unicorn 的 ARM 内存中，返回 ARM 地址。
ARM ext 通过这个地址能正确访问字符串内容。

由于 `string.subV` 在 strlib 中，无法直接访问 `ArmExtModule`。通过宿主 bridge 层
的回调函数实现：
- 在 mythroad.c 注册一个 `mr_subv_to_arm_ptr(str, len)` 回调
- `string.subV` 调用它把字符串拷贝到 ARM 内存，返回 ARM 地址
- 如果回调未注册（非 ARM ext 模式），回退到原始行为（返回宿主指针）

## 验证

```bash
bash scripts/test_cookie_submrp.sh
```

退出子 mrp 返回 cookie 后：
- 真机行为：直接显示文件管理页面（不发网络请求）
- 修复前模拟器：重新走启动流程（logo + 网络请求）
- 修复后模拟器：不闪 logo（_mr_param 传递成功），但仍未恢复文件管理页面

## 后续 issue：ARM ext 内存状态丢失

subV 指针修复后，cookie 的 `_mr_param='_RL'` 能正确传递给 ARM ext（不闪 logo）。
但页面仍未恢复到文件管理页面。根因：

**`mr_stop_ex` → `native_ext_reset()` → `arm_ext_unload()` 完全销毁了 ARM ext 内存。**

cookie 退出子 mrp 时走 `mr_timer` RESTART → `mr_stop()` → `mr_stop_ex(TRUE)` →
`native_ext_reset()`。这会 free 整个 `ArmExtModule->mem`（Unicorn 的 16MB ARM 内存块），
cookie 的所有页面状态数据丢失。cookie 重新加载时 `arm_ext_load` 创建全新的 ArmExtModule，
ARM ext 从 `mrc_init(code=0)` 从头执行。

真机上 `mr_stop_ex` 不释放 ARM ext 的代码/数据内存（它们在 Mythroad 堆中，`mr_stop_ex`
只释放屏幕缓冲等），所以 cookie 的页面状态在内存中保留，重新执行时直接恢复。

修复方向（架构级，需评估兼容性）：
- 在 RESTART 场景下不 `arm_ext_unload`，而是暂停 ARM ext 并保留其内存
- 或者让 `mr_stop_ex` 区分"临时停止"（RESTART）和"完全退出"（STOP）
- 需要处理多个 ARM ext 实例的情况（cookie 和子 mrp 各有自己的 ArmExtModule）
