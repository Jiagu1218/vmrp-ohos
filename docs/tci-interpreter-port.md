# TCI 解释器移植：绕过 HarmonyOS 7.0 PROT_EXEC 限制

## 背景

HarmonyOS 7.0（API 18+）实施「匿名内存执行权限管控」，禁止第三方应用分配含 `PROT_EXEC` 的内存。vmrp-ohos 依赖的 Unicorn Engine（QEMU TCG JIT）需要 RWX 内存作为代码翻译缓存，因此启动即崩溃。

官方授权通道（ACL 权限 `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY`）需走 AGC 审批流程。在等待审批期间，移植 **TCI（TCG Interpreter）**作为保底方案，使应用完全不依赖 `PROT_EXEC` 即可运行。

详见 [harmonyos7-execmem-issue.md](./harmonyos7-execmem-issue.md)。

## 方案原理

| | JIT（原方案） | TCI（保底方案） |
|---|---|---|
| **TCG backend** | 生成主机机器码（ARM64） | 序列化字节码（`[op,size,regs/imm]`） |
| **代码缓存内存** | `PROT_READ\|PROT_WRITE\|PROT_EXEC`（RWX） | `PROT_READ\|PROT_WRITE`（普通 RW） |
| **执行方式** | 直接跳转执行机器码 | C 语言 `switch(opc)` 解释器循环 |
| **HarmonyOS 7.0** | ❌ `mmap(PROT_RWX)` → EINVAL | ✅ `mmap(PROT_RW)` 成功 |
| **性能** | 基准（1×） | 慢 3-5×（MRP 低速业务可接受） |

TCI 通过 QEMU 既有的 `HAVE_TCG_QEMU_TB_EXEC` 钩子接入：定义该宏后，`tcg_qemu_tb_exec(env, tb_ptr)` 从「调用 code_gen_prologue 机器码」变为「调用 TCI 的 C 解释器函数」。Unicorn 5.0.1（基于 QEMU 5.0.1）的 `tcg.h:1355` 已内置此钩子。

## 参考实现

移植基于 **FUTO 的 `tci-emscripten` 分支**（https://gitlab.futo.org/baremetal/unicorn，分支 `tci-emscripten`）：

- 该分支基于 QEMU **5.1.0**（与本树 5.0.1 仅差一个次版本），TCI 文件从上游 QEMU 5.1 复制
- 解决的是同样的问题（W^X / 无 `PROT_EXEC`，原为 WASM/emscripten 场景）
- **未采用** FUTO 的 wasm 专用部分（`ffi.inc.c`、`global_helper_table`、per-arch 符号重命名、`setjmp` 替换、`UNALIGNED_*` 宏）——HarmonyOS 主机是 ARM64（64 位寄存器），不需要 wasm32 的 ABI hack

## 改动清单

### 1. 新增源文件：`scripts/tci/`（仓库内参考副本，构建时拷入子模块）

| 文件 | 行数 | 作用 | 来源 |
|------|------|------|------|
| `tci.c` | 1286 | TCI 解释器主循环（`tcg_qemu_tb_exec`） | FUTO，适配 5.0.1 + ARM64 |
| `tcg-target.inc.c` | 899 | TCI 后端序列化器（`tcg_out_op` 把 TCGOp 打包成字节码） | FUTO，原样 |
| `tcg-target.h` | 213 | TCI 后端头（定义 `HAVE_TCG_QEMU_TB_EXEC` + no-op `flush_icache_range`） | FUTO，原样 |

### 2. `tci.c` 相对 FUTO 原版的适配

- **移除 `#include "ffi.inc.c"` 与 `do_op_call` 调用**：改用 `#else` 分支的标准 `helper_function` fat-cast。64 位主机 ABI 直接用寄存器传参，不需要 wasm32 的 sizemask 分发表。
- **添加 `static uintptr_t tci_tb_ptr;` 声明**：FUTO 依赖 per-arch `#define tci_tb_ptr tci_tb_ptr_<arch>` 重命名（多目标编译避免符号冲突）；本项目只编译 ARM 单目标，直接用 static 全局即可。仅在 `GETPC` 定义时（CONFIG_DEBUG_TCG）使用。

### 3. `scripts/CMakeLists.txt`：TCI 补丁块（替换原 `OHOS_JIT_WXE`）

构建时（`add_subdirectory(vmrp)` 之前）注入以下补丁，标记 `OHOS_TCI`：

**(a) 文件拷贝**：`file(COPY)` 把 `scripts/tci/` 的 3 个文件拷到 unicorn 子模块树
- `tci.c` → `qemu/tcg/tci.c`
- `tcg-target.inc.c` → `qemu/tcg/tci/tcg-target.inc.c`
- `tcg-target.h` → `qemu/tcg/tci/tcg-target.h`

**(b) 补丁 `qemu/configure`**：
- 注入 `interpreter="yes"` 默认值（OHOS 强制 TCI）
- 添加 `--enable-interpreter` / `--disable-interpreter` 参数解析（第二段忽略段）
- 输出 `CONFIG_TCG_INTERPRETER=y` 到 `config-host.mak`（`create_config` 转成 `#define CONFIG_TCG_INTERPRETER 1`）
- Darwin `MAP_JIT` 检测仅在非解释器模式运行
- 后端 include 目录：解释器模式优先 `tcg/tci` 而非 `$ARCH`

**(c) 补丁 unicorn `CMakeLists.txt`**：
- `set(UNICORN_TARGET_ARCH "tci")`（覆盖检测出的 aarch64，让 `-I.../tcg/tci` 解析 `tcg-target.h`）
- `list(APPEND UNICORN_ARCH_COMMON qemu/tcg/tci.c)`（每个 softmmu 目标库编译解释器）
- configure 调用追加 `--enable-interpreter`

**(d0) 补丁 `tcg.h` + `tcg.c`**：backport QEMU 5.1 的 `tcg_op_defs_max` 字段（`tci/tcg-target.inc.c:877` 依赖）

**(d) 补丁 `translate-all.c`**：
- `alloc_code_gen_buffer`：`#if CONFIG_TCG_INTERPRETER` 时 `prot = PROT_WRITE|PROT_READ`（**去掉 EXEC，核心修复**）
- `MAP_JIT` 仅 `#if !CONFIG_TCG_INTERPRETER` 时启用
- 保留 32MB buffer 优化（`DEFAULT_CODE_GEN_BUFFER_SIZE_1` 1GB→32MB）

### 4. `scripts/build_libvmpp_ohos.bat`：`:restore_patched` 还原逻辑

新增还原：
- `git checkout` 还原 `qemu/configure`、`qemu/include/tcg/tcg.h`、`qemu/tcg/tcg.c`（受版本控制）
- `del` / `rmdir` 删除 `qemu/tcg/tci.c` 和 `qemu/tcg/tci/`（构建时拷入的未跟踪文件）

## 兼容性验证

移植前逐项验证了 QEMU 5.0.1 与 FUTO（5.1）TCI 文件的 API 兼容性：

| 检查项 | 结果 |
|--------|------|
| `tcg_out_op` 签名 `(TCGContext*, TCGOpcode, const TCGArg*, const int*)` | ✅ 一致 |
| `HAVE_TCG_QEMU_TB_EXEC` 钩子 | ✅ 已存在于 `tcg.h:1355` |
| `tcg_out_reloc` / `arg_label` / `tcg_current_code_size` / `tcg_out8/16/32/64` | ✅ 全部存在 |
| `set_jmp_reset_offset` / `QEMU_ALIGN_PTR_UP` / `tcg_patch32/64` / `patch_reloc` | ✅ 全部存在 |
| `TCGLabel` 结构（`has_value` / `u.value`） | ✅ 一致 |
| TCI backend/backend 用到的 `INDEX_op_*` 全在 5.0.1 `tcg-opc.h` | ✅ 无缺失 |
| `CONFIG_TCG_INTERPRETER=y` → `#define ... 1`（`create_config` 的 `CONFIG_*=y` 规则） | ✅ |
| softmmu helper（`helper_*_mmu`）签名 | ✅ 匹配 |
| `g2h`（`CONFIG_USER_ONLY` 宏）| ✅ Unicorn 是纯 softmmu，`#else` 死代码不影响 |
| 唯一差异：`tcg_op_defs_max` 字段（5.1 新增） | ⚠️ 已 backport（补丁 d0） |

## 构建与验证

### 构建

```bat
scripts\build_libvmpp_ohos.bat arm64-v8a
```

日志中应出现：
```
[OHOS] TCI: copied tci.c + tcg/tci/{tcg-target.inc.c,tcg-target.h}
[OHOS] TCI: patched qemu/configure (--enable-interpreter + CONFIG_TCG_INTERPRETER)
[OHOS] TCI: patched unicorn CMakeLists.txt (UNICORN_TARGET_ARCH=tci + tci.c)
[OHOS] TCI: patched tcg.h (added tcg_op_defs_max field)
[OHOS] TCI: patched tcg.c (tcg_op_defs_max init)
[OHOS] TCI: patched translate-all.c (RW buffer for interpreter, 32MB cap)
```

### 确认 TCI 已启用

```bat
REM 检查生成的 config-host.h
grep CONFIG_TCG_INTERPRETER build-libvmrp-arm64-v8a\config-host.h
REM 应输出: #define CONFIG_TCG_INTERPRETER 1

REM 检查 libvmrp.so 含 tcg_qemu_tb_exec 函数符号(JIT 模式该符号不存在)
C:\ohos_ndk\llvm\bin\llvm-nm.exe -D entry\src\main\cpp\prebuilt\arm64-v8a\libvmrp.so | findstr tcg_qemu_tb_exec
REM 应输出: 0000000000xxxxxx T tcg_qemu_tb_exec
```

### 真机验证

在 Mate 70 Pro / HarmonyOS 7.0.100 上：
- ✅ 应用启动不再崩溃（此前 `exit(1)` 在 `tcg_exec_init_arm`）
- ✅ 进程持续存活，渲染循环活跃
- ✅ 无 `SIGSEGV` / `SIGABRT` / faultlog

## 切回 JIT（ACL 权限审批通过后）

1. 在 AGC 申请 `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY`，更新 Profile 重签名
2. 移除 `scripts/CMakeLists.txt` 中的整个 TCI 补丁块（标记 `OHOS_TCI` 的部分）
3. 恢复 `translate-all.c` 的 `prot = PROT_WRITE | PROT_READ | PROT_EXEC`（JIT 需要 RWX）
4. 重新构建：此时 `tcg_qemu_tb_exec` 回到宏形式（调用 code_gen_prologue 机器码），性能恢复 1×

## 参考资料

- [FUTO tci-emscripten 分支](https://gitlab.futo.org/baremetal/unicorn/-/tree/tci-emscripten)
- [Unicorn issue #1695 — Add tcg-interpreter (tci) feature](https://github.com/unicorn-engine/unicorn/issues/1695)
- [QEMU TCI README](https://github.com/qemu/qemu/blob/master/tcg/tci/README)
- [HarmonyOS 匿名内存执行权限管控变更说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/changelogs-for-all-apps-b031)
- [JSVM-API 申请JIT权限指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/jsvm-apply-jit-profile)
