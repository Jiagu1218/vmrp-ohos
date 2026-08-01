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

**几乎确定可行**，理由：
1. 当前匿名 RWX 都能成功 → 文件后端 RX 更没问题
2. `memfd_create` 在 OHOS 上已知可用（之前诊断时返回了有效 fd=51）
3. chashaochang/unicorn-ohos 已在 HarmonyOS 上验证

**但有一个未验证点**：之前测试 `memfd_create + mprotect(PROT_EXEC)` 失败（EACCES）。Split-WX 的方式不同——它直接 `mmap(fd, PROT_EXEC)`（不是先 RW 再 mprotect），这个路径可能没被封。需要实际验证。

## 移植到 vmrp-ohos 的路径

### 方案 A：替换 unicorn 子模块

将 `vmrp/third_party/unicorn` 切换到 chashaochang/unicorn-ohos。风险：上游 vmrp 的 unicorn 版本（8028ec4，QEMU 5.0.1）与 unicorn-ohos 的版本可能不同，ABI/API 差异需评估。

### 方案 B：backport split-wx 补丁

从 unicorn-ohos 提取 split-wx 相关改动（4 个文件），通过 OHOS 补丁系统注入到现有 unicorn 子模块。改动量可控，与现有补丁系统兼容。

### 推荐时机

- **当前不需要**：设备 RWX 可用，JIT 直接运行
- **未来需要时**：当系统再次收紧 PROT_EXEC，且 TCI 性能不可接受时，优先尝试方案 B

## 与当前架构的关系

```
启动时探测 mmap(PROT_RWX)
├─ 成功 → libvmrp.so (JIT)          ← 当前设备走这条
├─ 失败 → libvmrp_tci.so (TCI)      ← PROT_EXEC 被禁时走这条
│
└─ 未来：Split-WX 方案可替代 TCI
    失败 → libvmrp_splitwx.so (JIT via 文件后端 RX)
    性能远优于 TCI，但依赖文件后端 PROT_EXEC 允许
```

Split-WX 可以作为第三个 so 加入双 so 方案，形成三级降级：
1. **JIT（匿名 RWX）**：最快，需要匿名 PROT_EXEC
2. **Split-WX JIT（文件后端 RX）**：接近原生，需要文件后端 PROT_EXEC
3. **TCI（纯解释器）**：最慢但最兼容，不需要任何可执行内存

## 参考资料

- [chashaochang/unicorn-ohos](https://github.com/chashaochang/unicorn-ohos)
- QEMU 上游 split-wx 机制：`accel/tcg/translate-all.c` 的 `alloc_code_gen_buffer_splitwx`
- macOS MAP_JIT 方案：`pthread_jit_write_protect_np()`（类似的 W^X 绕过）
- 当前 TCI 方案：[docs/tci-interpreter-port.md](./tci-interpreter-port.md)

---

*调研时间：2026-08-01*
*设备：Mate 70 Pro / HarmonyOS 7.0.100*
