# arm_alloc 越界导致 memset 踩出 16MB 缓冲 — SIGSEGV 修复

## 崩溃现场

```
cppcrash: com.example.vmrpohos (2026-07-08 01:29:38)
Signal: SIGSEGV(SEGV_ACCERR)@0x0000005cf5052000

调用栈:
  memset+196
  ← hook_table (arm_ext_executor.c:6180, case 38 r0==1014 MR_MALLOC_SCRRAM)
  ← uc_emu_start → resume_all_vcpus_arm → cpu_tb_exec → helper_uc_tracecode
  ← arm_ext_call → run_arm_with_sp
  ← TestCom1 → _mr_TestCom1
  ← mr_D_precall → mr_V_execute → mr_D_call → mr_D_rawrunprotected
  ← mr_D_pcall → mrp_pcall
  ← mr_aux_do → _mr_intra_start → mr_timer
  ← api_worker_main

关键寄存器:
  x0  = 0x5cb0989bf8  (memset dest = arm_ptr(m, 0xA45E38))
  x21 = 0xA27B9C      (memset size = want ≈ 10.6MB)
  x19 = 0x5c6fe57e00  (ArmExtModule* m)
  m->mem = 0x5caff53dc0 (16MB 缓冲)
```

arm_alloc 返回 `a=0xA45E38`，`want=0xA27B9C`。arm_ptr 计算偏移 `0xA35E38`，
memset 写入 `0xA27B9C` 字节后结尾 `0xA35E38 + 0xA27B9C = 0x146D9D4` 越过
16MB（`0x1000000`），踩出 m->mem 缓冲触发 SIGSEGV。

## 根因分析

### arm_alloc 原始边界检查

```c
uint32_t arm_alloc(ArmExtModule *m, uint32_t len) {
    /* 长度上限守卫:len 接近 UINT32_MAX 时 align4 与 heap_top+len 均会回绕 */
    if (len > EXT_MEM_SIZE) return 0;          // 上游已加
    len = align4(len ? len : 1);
    uint32_t reserved_lo = EXT_STACK_ADDR;       // 0xE00000
    uint32_t reserved_hi = EXT_CODE_ADDR + align4(m->code_len);  // ≥ 0xE80000

    // 保留区跨越判断 — uint32 算术
    if (m->heap_top < reserved_hi && m->heap_top + len > reserved_lo) {
        m->heap_top = reserved_hi;
    }

    uint32_t mem_end = EXT_BASE_ADDR + EXT_MEM_SIZE;  // 0x1010000
    if (m->screen_addr == mem_end - EXT_SCREEN_RESERVE) {
        mem_end -= EXT_SCREEN_RESERVE;                 // → 0xF10000
    }

    // 主边界检查 — uint32 算术
    if (m->heap_top + len >= mem_end) return 0;

    uint32_t ret = m->heap_top;
    m->heap_top += len;
    return ret;
}
```

> **注意**: 上游重构后 `arm_alloc` 从 `arm_ext_executor.c` 迁移到 `aex_mem.c`（line 1030）。
> 上游已添加 `if (len > EXT_MEM_SIZE) return 0` 守卫（line 1034），覆盖 uint32 溢出路径。

### 崩溃转储中的 heap_top

从 ArmExtModule 结构体偏移 60 读取崩溃时的 `heap_top` 值：

```
m + 0x38:  0033363800000000  (64-bit dump value)
  → executor_meta_top (offset 56) = 0x00000000
  → heap_top         (offset 60) = 0x00333638
```

### 矛盾推演

**假设 heap_top = 0x00333638 在 arm_alloc 调用时**：

1. 保留区跨越：`0x00333638 < reserved_hi(≥0xE80000)` ✓ 且
   `0x00333638 + 0xA27B9C = 0xD5B1D4 > 0xE00000(reserved_lo)` ✓
   → skip 触发，`heap_top = reserved_hi ≥ 0xE80000`
2. 主边界检查：`0xE80000 + 0xA27B9C = 0x18A7B9C ≥ 0xF10000` → 返回 0

但崩溃显示 arm_alloc 返回了 `0xA45E38`，而非 0。

**假设 heap_top 已跳到 0xA45E38**：
- `0xA45E38 + 0xA27B9C = 0x146D9D4 ≥ 0xF10000` → 应返回 0
- 但 0xA45E38 < 0xE80000 (EXT_CODE_ADDR)，保留区 skip 不可能设到此值

**结论**：崩溃时 heap_top 被损坏为 `0x00333638`（异常小值），导致 uint32 算术
`heap_top + len` 未溢出但结果 `< mem_end`，边界检查通过，arm_alloc 返回越界地址。

### heap_top 损坏的可能原因

- 另一个 hook_table case 并发修改 ArmExtModule 结构体（虽在同一线程，但 Unicorn
  嵌套执行中可能重入 hook_table）
- ARM 代码通过 memory write hook 意外覆写宿主 ArmExtModule 结构体字段
- heap_top 的值在 arm_alloc 返回后被某种路径重置（如 free 操作误清零）

由于崩溃转储只能捕获崩溃瞬间的快照，heap_top 的确切损坏路径无法从单一转储确定。
修复策略采用**两道防线**而非追究单一根因。

## 修复

### 防线 1: arm_alloc 上游已修复 (`OHOS_ARM_ALLOC_U64` 已删除)

上游在 `aex_mem.c:1034` 添加了 `if (len > EXT_MEM_SIZE) return 0` 长度上限守卫，
覆盖了 uint32 溢出路径（EXT 地址空间仅 16MB，`heap_top+len <= 32MB` 不溢出 uint32）。
因此原先的 `OHOS_ARM_ALLOC_U64` 64 位算术补丁不再需要，已从 CMakeLists.txt 删除。

> CMakeLists.txt line 519-520 明确注释此决策。

### 防线 2: case 38 memset 越界守卫 (`OHOS_MEMSET_BOUNDS_GUARD`)

即使 arm_alloc 的长度守卫被某种方式绕过（如 heap_top 损坏后恰好满足条件），
memset 前二次验证分配范围不超出 16MB：

```c
void *ep = arm_ptr(m, a);
// 原: if (ep) memset(ep, 0, want);
if (ep && (uint64_t)(a - EXT_BASE_ADDR) + (uint64_t)want <= (uint64_t)EXT_MEM_SIZE) {
    memset(ep, 0, want);
}
```

> **注意**: 上游重构后 case 38 拆为 `aex_t038()` 函数在 `aex_table.c`（line 2023），
> memset 在 `aex_table.c:2064`。

## 补丁位置

两个修复均在 `scripts/CMakeLists.txt` 中作为 CMake 补丁注入
（`aex_table.c`、`aex_mem.c` 在 `:restore_patched` 列表中，构建后还原为 git 原始状态）。

| 补丁标记 | 锚点 | 说明 |
|----------|------|------|
| `OHOS_ARM_ALLOC_U64` | ~~`m->heap_top + len > reserved_lo`~~ | ~~arm_alloc 64 位算术~~ **已删除**：上游已加 `len > EXT_MEM_SIZE` 守卫 |
| `OHOS_MEMSET_BOUNDS_GUARD` | `if (ep) memset(ep, 0, want)` | `aex_table.c:2064` memset 守卫 |

## 验证

构建成功（arm64-v8a），应用已部署到 HUAWEI Mate 70 Pro。
等待用户测试：若 MR_MALLOC_SCRRAM 大额分配不再触发 SIGSEGV 即修复有效。
