# cookie.mrp 启动子 mrp 修复（OHOS_RESTART_READBACK）

## 问题

dsm_gm.mrp 启动 cookie.mrp 正常，但 cookie.mrp 启动其它 mrp 时：
- 子 mrp 无法启动
- 退出后无法返回 cookie（返回到了 dsm_gm）

真机上一切正常。

## 根因（4 层）

模拟器中 ARM EXT 代码通过 Unicorn 运行，ARM 内存与宿主全局变量**分离**。
真机上 ARM 代码与宿主共享同一份 `char[128]` 全局缓冲区（通过函数表
`table[100..103]` / `table[138]` 暴露），ARM 代码写入后宿主立即可见。

### 1. RESTART(3) 与 STOP(4) 混为一谈

`arm_ext_finish_callback_state`（`arm_ext_executor.c:1240`）对 `arm_state >= 3`
一律调 `mr_exit()`：

```c
if (arm_state >= 3) {   // RESTART(3) 和 STOP(4) 混为一谈
    mr_exit();           // ← 错误
    return 1;
}
```

真机 `mr_timer()` RESTART 分支（`mythroad.c:4222`）直接
`mr_stop()` + `_mr_intra_start(start_filename)`，**不调 `mr_exit`**。
`mr_exit()` 内部的 `mr_restart_old_app()` 会用 `old_*` 覆盖 `start_filename`，
破坏 ARM 代码刚写的新目标。

### 2. pack_filename 未回读

`arm_ext_executor.c` 启动时把宿主全局单向复制到 ARM 内存（line 971-977），
回调结束后只回读 `mr_state`（`arm_ext_finish_callback_state`）。
ARM 代码写入 `table[100]`（pack_filename）的新目标包名**从未被回读**到宿主全局。

### 3. start_filename 回读到错误值

回读 `table[101]`（start_filename）读到的是 cookie 启动时设的 `cfunction.ext`
（ARM ext 二进制），而不是子 mrp 的入口。`mrp_dofile(vm_state, "cfunction.ext")`
卡住——那是 ARM ext 二进制，不是 Lua 脚本。

真机上 `mr_start_dsmC` 启动子 mrp 时会清空 `start_filename`（memclr 128 bytes），
`_mr_intra_start(start_filename)` 收到空串后使用 mrp 包默认入口 `start.mr`。

### 4. old_pack_filename 缓冲区溢出

`table[102]`（old_pack_filename）用 `alloc_string("")` 分配——空串只分配 **1 字节**。
真机上 `table[102]` 指向 `char old_pack_filename[128]` 全局数组，ARM 代码可以
`strcpy` 写入最多 127 字节的包名。模拟器里 ARM 代码 strcpy 到 1 字节缓冲导致溢出，
`old_pack_filename` 只剩残留的 `'t'`（实测），退出子 mrp 后返回到了错误的应用。

## 修复

以 CMake 补丁形式实现（`scripts/CMakeLists.txt`，标记 `OHOS_RESTART_READBACK`），
不修改上游源码，build 后由 `:restore_patched` 自动恢复。

### 补丁 A：mythroad.c — 添加 setter + 空入口 fallback

1. 补齐 `mr_set_pack_filename` / `mr_set_start_filename` / `mr_set_start_fileparameter`
   三个 setter（上游只有 old_* 版本）。
2. `_mr_intra_start` 中 `appExName` 为空时 fallback 到 `MR_START_FILE`（`"start.mr"`），
   与 `mr_start_dsm` 的 `ext` 默认值逻辑一致。

### 补丁 B：arm_ext_executor.c — 回读 + RESTART/STOP 区分 + 固定缓冲

1. **`read_table_string(m, index)`**：读取 `table[index]` 槽中的 ARM 指针，解引用得到
   C 字符串。
2. **`arm_ext_readback_filename_globals(m)`**：在 RESTART 检测时把 ARM 侧
   `table[100]`（pack_filename）和 `table[102/103/138]`（old_pack/old_start/param）
   回读到宿主全局。`start_filename` 不回读（清空，让 fallback 到 start.mr）。
3. **`arm_ext_finish_callback_state`**：区分 RESTART(3) 与 STOP(4)。
   - RESTART(3)：回读 + 设宿主 `mr_state=3`，**不调 `mr_exit()`**，让 `mr_timer()`
     自然消费。
   - STOP(4)/ERROR(5)：保留原有 `mr_exit()` 行为。
4. **table[101-103,138] 改用 `arm_alloc(128)` 固定缓冲**（而非 `alloc_string` 精确长度），
   与真机 `char[128]` ABI 一致，ARM 代码 strcpy 不再溢出。

### 反汇编依据

- `MRF_RunFile`（`full1968_mythroad.disasm:5827` / `mythroad.c:2930`）：
  设 pack/start + `mr_state=RESTART`，不调 `mr_exit`。
- `mr_timer` RESTART 分支（`full1968_mythroad.disasm:10585` / `mythroad.c:4222`）：
  直接 `mr_stop()` + `_mr_intra_start(start_filename)`。
- `mr_start_dsmC`（`mythroad_mini_full.disasm:4189`）：
  memclr `start_filename` / `old_start_filename` / `start_fileparameter`（各 128 bytes）。
- 函数表布局（`mythroad.c:508-511` / `mythroad_mini.c:308-311`）：
  `table[100]=pack_filename`, `[101]=start_filename`, `[102]=old_pack_filename`,
  `[103]=old_start_filename`, `[138]=start_fileparameter`，每个都是 `char[128]`。

## 验证

自动化测试脚本：`scripts/test_cookie_submrp.sh`

```bash
# dsm_gm → 冒泡 → 启动应用 → 等10秒 → 菜单 → 文件管理 → 大富翁4 → 退出
export PATH="$PATH:C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains"
bash scripts/test_cookie_submrp.sh
```

验证通过的标准（看 `vmrp_core` hilog）：
- `dofile('start.mr')` 出现 3 次：dsm_gm → cookie → 子mrp → 返回cookie
- 子mrp 启动后 ARM ext 正常加载（`arm_ext_executor: wrapper probes`）
- 退出子mrp 后返回 cookie（不是 dsm_gm）

## 构建

```bash
scripts/build_libvmpp_ohos.bat arm64-v8a   # 真机
scripts/build_libvmpp_ohos.bat x86_64      # 模拟器
```

两者均已构建成功（76 targets），无编译错误，无残留诊断 printf。

## 影响范围

- 仅影响 `arm_ext_finish_callback_state` 中 `mr_state >= 3` 的处理路径
- RESTART(3)：新增回读 + 不调 mr_exit（真机语义）
- STOP(4)/ERROR(5)：行为不变（仍调 mr_exit）
- table[101-103,138] 缓冲区从精确长度改为 128 字节固定（与真机 ABI 一致）
- 上游源码不受污染（CMake 补丁 + restore_patched）
