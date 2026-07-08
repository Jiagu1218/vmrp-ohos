# SkyEngine 内存扩展接口适配 — OHOS_PLATEX_MEM_EXT

## 概述

SkyEngine 平台定义了 6 个内存扩展接口（通过 `mr_platEx` 调用），用于在内存紧张的功能机上提供额外的缓冲区。vmrp-ohos 现已完整实现这些接口。

参考文档: https://gddhy.net/2022/skyengine-api/ (内存扩展接口章节)

## 接口清单

| code | 名称 | 用途 | OHOS 实现状态 |
|------|------|------|-------------|
| 1001 | 获取屏幕缓冲 | 申请第二内存作为 VM 屏幕缓冲 | ✅ 已实现 |
| 1002 | 释放屏幕缓冲 | 释放 1001 申请的第二内存 | ✅ 已实现 |
| 1012 | 申请内部 RAM | 申请内部 cache (IRAM) | ✅ 已实现 |
| 1013 | 释放内部 RAM | 释放 1012 申请的 cache | ✅ 已实现 |
| 1014 | 申请扩展内存 | 申请扩展内存 (exRAM) | ✅ 上游已实现 |
| 1015 | 释放扩展内存 | 释放 1014 申请的 exRAM | ✅ 上游已实现 |

## 实现架构

### 双路径设计

内存扩展接口在 ARM ext 模式和非 ext 模式下有不同实现：

```
MRP ARM 代码调 table[38] (mr_platEx)
    ↓
arm_ext_executor.c 的 table[38] handler
    ├─ r0==1001 → arm_alloc(m, sw*sh*2)  [ARM ext 拦截]
    ├─ r0==1002 → 清零 screen_buf_addr/len
    ├─ r0==1012 → arm_alloc(m, want)
    ├─ r0==1013 → 清零 iram_addr/len
    ├─ r0==1014 → arm_alloc(m, want)      [上游已有]
    ├─ r0==1015 → MR_SUCCESS              [上游已有]
    └─ 其他 code → 走通用 mr_platEx() → dsm.c

DSM 层 (非 ARM ext 路径，如 Lua 模式):
    dsm.c mr_platEx()
    ├─ case 1001 → calloc(1, SCREEN_WIDTH*SCREEN_HEIGHT*2)
    ├─ case 1002 → free(input)
    ├─ case 1012 → calloc(1, input_len)
    ├─ case 1013 → free(input)
    ├─ case 1014 → MR_IGNORE
    └─ case 1015 → MR_IGNORE
```

### ARM ext 拦截

ARM ext 模式下，MRP 的 ARM 代码通过 `table[38]` 调用 `mr_platEx` 时，分配的内存必须是 **ARM 可见的 32 位虚拟地址**（在 Unicorn 映射的内存空间中），guest 代码才能通过 ARM 地址直接读写。因此不能使用 host 的 `malloc`，必须用 `arm_alloc()` 从 Unicorn 虚拟堆分配。

**分配后回写流程**（与 1014/1015 同模式）：

1. `arm_alloc(m, want)` 返回 ARM 地址 `a`
2. `uc_mem_write(uc, outputp, &a, 4)` 将 ARM 地址写回 guest 的 output 指针
3. `uc_mem_write(uc, outlenp, &want, 4)` 将长度写回 guest 的 output_len 指针
4. Guest 代码通过返回的 ARM 地址直接访问分配的内存

### dsm.c host 路径

非 ARM ext 路径（Lua VM 等不经过 Unicorn 的调用）使用 host 侧 `calloc`/`free`：
- `calloc` 替代 `malloc+memset`（避免 dsm.c 本地 `string.h` 覆盖系统头导致 `memset` 隐式声明警告）
- 屏幕缓冲大小用 `SCREEN_WIDTH * SCREEN_HEIGHT * 2`（来自 `vmrp_config`，非固定值）

## 修改文件

### 1. `vmrp/src/include/arm_ext_internal.h` — 新增字段

```c
uint32_t exram_addr;     // 上游已有 (1014 exRAM)
uint32_t exram_len;
/* OHOS_MEM_EXT: platEx(1001) 第二屏幕缓冲 / platEx(1012) 内部 RAM */
uint32_t screen_buf_addr;   // 1001 屏幕缓冲 ARM 地址
uint32_t screen_buf_len;    // 1001 屏幕缓冲长度
uint32_t iram_addr;         // 1012 内部 RAM ARM 地址
uint32_t iram_len;          // 1012 内部 RAM 长度
```

文件不在 `:restore_patched` 列表中，直接编辑持久保存。

### 2. `scripts/CMakeLists.txt` — CMake patch (OHOS_PLATEX_MEM_EXT)

在 `arm_ext_executor.c` 的 `table[38]` handler 中，于 1014 拦截块之前插入 1001/1002/1012/1013 拦截：

- **幂等标记**: `OHOS_PLATEX_MEM_EXT`
- **锚点**: `MR_MALLOC_SCRRAM/MR_FREE_SCRRAM provide scratch RAM` 注释
- **替换方式**: `string(REPLACE)` 在锚点前插入新代码块

1001 屏幕缓冲大小计算：
```c
uint32_t sw = 240, sh = 320;  // 兜底值
if (m->screen_w_slot) {
    void *sp = arm_ptr(m, m->screen_w_slot);
    if (sp) memcpy(&sw, sp, 4);  // 从 table[92] 读 mr_screen_w
}
if (m->screen_h_slot) {
    void *sp = arm_ptr(m, m->screen_h_slot);
    if (sp) memcpy(&sh, sp, 4);  // 从 table[93] 读 mr_screen_h
}
if (sw < 16 || sw > 1024) sw = 240;  // 防御性校验
if (sh < 16 || sh > 1024) sh = 320;
want = sw * sh * 2;
```

支持横屏模式（如 gtcm 的 480x320 逻辑画布）等动态分辨率场景。

### 3. `vmrp/src/mythroad/dsm.c` — host 路径实现

在 `mr_platEx()` 的 switch 中添加 case 1001/1002，改进 case 1012/1013：

```c
case 1001: {
    int32 want = SCREEN_WIDTH * SCREEN_HEIGHT * 2;
    if (want <= 0) want = 240 * 320 * 2;
    uint8 *p = (uint8 *)calloc(1, want);
    if (p) {
        *output = p;
        *output_len = want;
        return MR_SUCCESS;
    }
    return MR_IGNORE;
}
case 1002: {
    if (input) free(input);
    return MR_SUCCESS;
}
case 1012: {
    if (input_len > 0) {
        uint8 *p = (uint8 *)calloc(1, input_len);
        if (p) {
            *output = p;
            return MR_SUCCESS;
        }
    }
    *output = NULL;
    return MR_SUCCESS;
}
case 1013: {
    if (input) free(input);
    return MR_SUCCESS;
}
```

文件不在 `:restore_patched` 列表中，直接编辑持久保存。

## 设计决策

### 为什么不启用 MR_SECOND_BUF

`mythroad.c` 中有 `#ifdef MR_SECOND_BUF` 代码块，启用后 `mr_screenBuf` 会使用 `mr_platEx(1001)` 返回的第二内存。不启用的原因：

1. **MR_SECOND_BUF 用于功能机内存紧张场景**：OHOS 设备没有此限制
2. **ARM ext 模式下 `mr_screenBuf` 是 ARM 堆地址**：通过 `mr_malloc` 分配在 Unicorn 映射内存中，ARM ext 绘图逻辑可直接访问
3. **启用后 `mr_screenBuf` 变为 host malloc 指针**：ARM ext 的 host 侧绘图操作需要额外同步机制
4. **1001/1002 的核心价值在 ARM ext 拦截**：MRP 的 ARM 代码通过 `table[38]` 调用时获得 ARM 地址可用的缓冲区，这不需要 MR_SECOND_BUF

### 为什么用 calloc 而非 malloc+memset

dsm.c 包含 `#include "./include/string.h"`，该本地头文件覆盖了系统的 `<string.h>`，只声明了 `memset2` 而没有 `memset`。使用 `calloc` 避免隐式函数声明警告，同时自动清零分配的内存。

### 释放策略

ARM ext 模式下，1002/1013 只清零 `addr/len` 字段，**不归还 ARM 堆内存**。这与 1015（exRAM 释放）的策略一致——`arm_alloc` 没有对应的 free 函数，ARM 堆内存生命周期与 `ArmExtModule` 绑定，ext 卸载时统一释放。

## 配置行

CMake configure 输出：
```
-- [OHOS] Patched platEx(1001/1002/1012/1013) memory ext (OHOS_PLATEX_MEM_EXT)
```
