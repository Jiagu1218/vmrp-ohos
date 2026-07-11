# UC_ERR_EXCEPTION 堆数据优雅恢复 — OHOS_EXCEPTION_HEAP_RECOVERY

## 问题现场

```
vmrp_core: arm_ext_executor: uc_emu_start(0xE800B0) failed: 21 (Unhandled CPU exception (UC_ERR_EXCEPTION))
vmrp_core: arm_ext_executor: pc bytes @0x226354: 1E FF 2F E1 21 01 00 00 26 00 02 00 38 B5 42 1E
```

- `start=0xE800B0` = `EXT_CODE_ADDR + 0xB0`，timer 回调入口
- 错误码 21 = `UC_ERR_EXCEPTION`
- PC=0x226354 位于堆区（`EXT_HEAP_ADDR ~ EXT_BASE_ADDR+EXT_MEM_SIZE`）
- 字节 `1E FF 2F E1` = ARM 指令 `bx lr`，但堆区存数据而非代码

## 根因分析

### 调用链

1. Timer 回调执行 → guest ARM 代码触发 SVC 软中断
2. `aex_exec.c:51-57` `arm_ext_mark_unhandled_intr()` 设置 `m->pending_intr_no = intno`
3. `uc_emu_start` 本身返回 `UC_ERR_OK`，但 `run_arm_with_sp()` (line 100) 内因 `pending_intr_no != 0` **人为将 err 改为 UC_ERR_EXCEPTION**（line 109/148）：
   ```c
   if (err == UC_ERR_OK && m->pending_intr_no) {
       err = UC_ERR_EXCEPTION;
       reg_write32(m->uc, UC_ARM_REG_PC, m->pending_intr_pc);
   }
   ```
4. PC 被设为 `pending_intr_pc`，进入错误恢复流程

### 为什么恢复失败

`run_arm_with_sp` 中有三个堆数据恢复块（`aex_exec.c:164/186/215`），条件均为：

```c
if (err == UC_ERR_INSN_INVALID && pc >= EXT_...)
```

但此时 `err == UC_ERR_EXCEPTION`（因 pending_intr_no 人为设置），**不匹配 UC_ERR_INSN_INVALID**：

1. 第 164 行 `err == UC_ERR_INSN_INVALID` — 栈漂进代码段，不匹配 ❌
2. 第 186 行 `err == UC_ERR_INSN_INVALID` — PC-2 是 Thumb-2 中点，不匹配 ❌
3. 第 215 行 `err == UC_ERR_INSN_INVALID` — 堆数据/FF FF/lr_in_wrapper，不匹配 ❌
4. 第 249 行 `err == UC_ERR_EXCEPTION` — 匹配，但检查 `sp_diff < 0x4000`，PC=0x226354 与 SP 距离远 ❌
5. 最终走到第 260 行打印错误日志，返回 `MR_FAILED` → **timer 永久死亡**

## 修复方案

**CMake patch: OHOS_EXCEPTION_HEAP_RECOVERY**

将三个 `err == UC_ERR_INSN_INVALID && pc >=` 条件扩展为同时覆盖 `UC_ERR_EXCEPTION`：

```c
// 修复前
if (err == UC_ERR_INSN_INVALID && pc >= EXT_CODE_ADDR ...)

// 修复后
if ((err == UC_ERR_INSN_INVALID || err == UC_ERR_EXCEPTION) && pc >= EXT_CODE_ADDR ... /* OHOS_EXCEPTION_HEAP_RECOVERY */)
```

三个恢复块全部生效（文件 `aex_exec.c`，上游重构从 `arm_ext_executor.c` 拆出）：
| 行号 | PC 范围 | 恢复行为 |
|------|---------|---------|
| 164 | `EXT_CODE_ADDR ~ EXT_CODE_ADDR+code_len` | 栈漂进代码段 → 干净退出 |
| 186 | `EXT_HEAP_ADDR ~ +2` | PC-2 是 Thumb-2 指令中点 → 干净退出 |
| 215 | `EXT_HEAP_ADDR ~ EXT_BASE_ADDR+EXT_MEM_SIZE` | 堆数据（0xFF/0x00/lr_in_wrapper）→ 干净退出 |

## 实现细节

- **文件**: `scripts/CMakeLists.txt`，独立 patch 块，目标 `aex_exec.c`
- **幂等标记**: `OHOS_EXCEPTION_HEAP_RECOVERY`
- **替换方式**: `string(REPLACE)` 批量替换 `err == UC_ERR_INSN_INVALID && pc >=` 为带 EXCEPTION 扩展的版本
- **替换次数**: 3 处（源码中有 3 个匹配点，`string(REPLACE)` 默认 replace all）
- **不影响**: 第 249 行的 `if (err == UC_ERR_EXCEPTION)` 栈近 SP 检查仍然独立保留

## 影响分析

- **正面**: pending_intr_no 导致的 EXCEPTION 不再杀死 timer，游戏逻辑可以继续
- **风险**: 当 PC 在代码区且 err=EXCEPTION 时，也可能被当作干净退出——但代码区的恢复语义是"栈漂进代码段无法继续，结束当前 callback 让下次 timer 继续"，对 EXCEPTION 同样合理
- **与 UNMAPPED_GRACEFUL_EXIT 互补**: UNMAPPED 处理内存访问越界，EXCEPTION_HEAP_RECOVERY 处理 CPU 异常后的 PC 落点恢复

## 配置行

CMake configure 输出：
```
-- [OHOS] Patched UC_ERR_EXCEPTION heap recovery (OHOS_EXCEPTION_HEAP_RECOVERY)
```
