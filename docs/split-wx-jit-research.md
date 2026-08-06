# Split-WX JIT 方案调研（替代 TCI 的潜在方案）

## 背景

当前 vmrp-ohos 用 TCI 解释器绕过 HarmonyOS 7.0 的 PROT_EXEC 限制。TCI 性能比 JIT 慢 5-10×，虽然 MRP 低速业务可接受，但存在更优方案。

社区项目 [chashaochang/unicorn-ohos](https://github.com/chashaochang/unicorn-ohos) 实现了 **Split-WX（读写/执行分离映射）** 方案，能在不牺牲 JIT 性能的前提下绕过同样的限制。

## Split-WX 原理

HarmonyOS 7.0 禁止的是**匿名可执行内存**（`MAP_ANONYMOUS | PROT_EXEC`），但允许**文件后端的可执行映射**。Split-WX 利用这一点：

```
memfd_create("tcg-jit") → fd
mmap(fd, PROT_READ|PROT_WRITE, MAP_SHARED) → RW 映射（写 JIT 代码）
mmap(fd, PROT_READ|PROT_EXEC,  MAP_SHARED) → RX 映射（执行 JIT 代码）
close(fd)  ← 两个映射独立存活
```

- **RW 映射**：TCG 后端把翻译后的机器码写入这里
- **RX 映射**：`cpu_exec` 从这里跳进去执行
- 两者通过 `MAP_SHARED` 映射同一个 fd，写入 RW 立即反映到 RX
- 地址转换用一个常量偏移 `splitwx_diff = RX_base - RW_base`

## 与 TCI 对比

| 维度 | Split-WX | TCI（当前方案） |
|------|----------|----------------|
| 性能 | 接近原生 JIT（仅多一次指针加法） | 慢 5-10× |
| PROT_EXEC 需求 | 需要文件后端 RX 映射 | 完全不需要 |
| 内存开销 | 2×（RW + RX 两个同等大小映射） | 1× |
| HarmonyOS 兼容性 | 依赖文件后端 PROT_EXEC 允许 | 最稳（不碰可执行内存） |
| Unicorn 改动量 | 中（translate-all.c + cpu-exec.c + tcg.h + exec-all.h） | 大（完整 TCI 后端 + 解释器） |
| 代码来源 | QEMU 上游原生 split-wx 机制，移植成熟 | FUTO tci-emscripten 分支 backport |

## chashaochang/unicorn-ohos 的实现要点

### 文件后端 fd 创建（三级 fallback）

```c
// 首选：memfd_create（匿名内存文件，内核 tmpfs 后端）
fd = syscall(SYS_memfd_create, "tcg-jit", MFD_CLOEXEC);

// 回退 1：O_TMPFILE（TMPDIR 目录未命名临时文件）
fd = open(dir, O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);

// 回退 2：mkstemp + 立即 unlink（命名临时文件删文件名，fd 保留）
fd = mkstemp(tmpl); unlink(tmpl);

// 所有路径都 ftruncate(fd, size) 撑到目标大小
ftruncate(fd, (off_t)size);
```

### 双映射建立

```c
static bool alloc_code_gen_buffer_splitwx(uc, size, &buf_rw) {
    fd = tcg_create_splitwx_fd(size);
    rw = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    rx = mmap(NULL, size, PROT_READ | PROT_EXEC,  MAP_SHARED, fd, 0);
    close(fd);
    tcg_ctx->splitwx_diff = (char*)rx - (char*)rw;
    tcg_ctx->initial_buffer_rx = rx;
    *buf_rw = rw;
}
```

### 地址转换

- **写入 TB 时**：TCG 后端写到 RW 地址（`code_gen_ptr`），存 `tb->tc_rw_ptr = RW 地址`
- **执行 TB 时**：`tb->tc.ptr = tc_rw_ptr + splitwx_diff`（转成 RX 地址），`cpu_exec` 跳进去
- **TB 链接 patch**：写入位置用 `tc_rw_ptr`（RW），目标地址减 `splitwx_diff`（RX→RW 坐标）
- **异常回溯**：`GETPC()` 返回 RX 地址，减 `splitwx_diff` 转回 RW 查 TB

### 涉及文件

| 文件 | 改动 |
|------|------|
| `qemu/accel/tcg/translate-all.c` | split-wx 缓冲分配、`tb_gen_code` 双指针、`cpu_restore_state` 反向转换 |
| `qemu/accel/tcg/cpu-exec.c` | `tb_set_jmp_target` 坐标转换 |
| `qemu/include/tcg/tcg.h` | `TCGContext` 加 `splitwx_diff`/`splitwx_enabled`/`initial_buffer_rx` |
| `qemu/include/exec/exec-all.h` | `TranslationBlock` 加 `tc_rw_ptr` 字段 |

## 当前状态评估

### 设备状态变化

诊断过程中发现：**设备 `mmap(PROT_RWX)` 匿名已成功**（显示 JIT 模式）。说明当前系统状态下 PROT_EXEC 限制已解除（可能是系统更新或临时状态）。此时：
- JIT 直接可用，不需要 TCI 也不需要 Split-WX
- 但未来系统可能再次收紧

### Split-WX 在 OHOS 上的可行性

**已验证不可行**（2026-08-05，Mate 70 Pro / HarmonyOS 7.0）。

实机 probe 结果：
```
[SWX-PROBE] memfd_create: fd=<有效>        ← 成功
[SWX-PROBE] mmap RW: <有效>                 ← 成功
[SWX-PROBE] mmap RX(file-backed PROT_EXEC): EACCES  ← 失败！
[SWX-PROBE] ✗ Split-WX 不可行
```

`memfd_create` 和 RW 映射都成功，但 `mmap(fd, PROT_READ|PROT_EXEC, MAP_SHARED)` 返回
EACCES——文件后端的 PROT_EXEC 也被内核拒绝。这与之前 `mprotect(PROT_EXEC)` 失败一致，
说明 HarmonyOS 7.0 的 PROT_EXEC 限制是全面的，不区分匿名/文件后端、mmap/mprotect。

**结论：Split-WX 方案在 HarmonyOS 7.0 上彻底排除。TCI 仍是唯一可靠的保底方案。**

chashaochang/unicorn-ohos 能工作的原因可能是：不同的 OHOS 版本/设备/ACL 权限配置，
或其测试环境有 `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY` ACL 权限。

## 移植到 vmrp-ohos 的路径

### 方案 A：替换 unicorn 子模块

将 `vmrp/third_party/unicorn` 切换到 chashaochang/unicorn-ohos。风险：上游 vmrp 的 unicorn 版本（8028ec4，QEMU 5.0.1）与 unicorn-ohos 的版本可能不同，ABI/API 差异需评估。

### 方案 B：backport split-wx 补丁

从 unicorn-ohos 提取 split-wx 相关改动（4 个文件），通过 OHOS 补丁系统注入到现有 unicorn 子模块。改动量可控，与现有补丁系统兼容。

### 推荐时机

**已排除，不再考虑**。2026-08-05 实机验证 `mmap(fd, PROT_EXEC)` 返回 EACCES，
Split-WX 在 HarmonyOS 7.0 上不可行。TCI 是唯一可靠的 PROT_EXEC-free 方案。

## 与当前架构的关系

```
启动时探测 mmap(PROT_RWX)
├─ 成功 → libvmrp.so (JIT)          ← 当前设备走这条
└─ 失败 → libvmrp_tci.so (TCI)      ← PROT_EXEC 被禁时走这条

Split-WX 已排除：mmap(fd, PROT_EXEC) 在 OHOS 7.0 上 EACCES
```

当前二级降级（JIT → TCI）是最终架构，不再扩展三级降级。

## 参考资料

- [chashaochang/unicorn-ohos](https://github.com/chashaochang/unicorn-ohos)
- QEMU 上游 split-wx 机制：`accel/tcg/translate-all.c` 的 `alloc_code_gen_buffer_splitwx`
- macOS MAP_JIT 方案：`pthread_jit_write_protect_np()`（类似的 W^X 绕过）
- 当前 TCI 方案：[docs/tci-interpreter-port.md](./tci-interpreter-port.md)

---

*调研时间：2026-08-01*
*设备：Mate 70 Pro / HarmonyOS 7.0.100*
