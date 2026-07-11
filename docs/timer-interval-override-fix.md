# arm_ext_call_dispatch 定时器间隔覆盖修复 — OHOS_TIMER_NO_OVERRIDE

## 问题现场

MRP 应用内设置 1 分钟定时退出，实际约 10 秒即退出。定时器触发频率约为预期的 6~20 倍。

## 根因分析

### 调用链

1. Worker 线程等待 `api_timer_due_ms` 到期 → 调 `timer()` → `mr_timer()`
2. `mr_timer()` → `arm_ext_primary_helper()` 返回非0 → `arm_ext_call_dispatch(native_ext, 0, 50)`
3. `arm_ext_call_dispatch` 内执行 `run_arm_with_sp()` — ARM 代码运行 timer callback
4. ARM callback 结束时调 `table[31]` → `mr_timerStart(T)` （T 是 MRP 应用想要的间隔，如 1000ms）
   - 设 `api_timer_due_ms = api_now_ms() + T`（如 now+1000）
5. `sync_timer_state_from_arm()` — 同步 timer state，`host_timer_pending` 保持为 1
6. Post-dispatch 检查 wrapper queue 是否还有节点 → **无条件调** `mr_timerStart((uint16)timer_interval)` = `mr_timerStart(50)`
   - **覆盖** `api_timer_due_ms = api_now_ms() + 50`

### 时序示意

```
ARM 代码调 table[31] → mr_timerStart(1000) → api_timer_due_ms = now + 1000
                                                      ↓ 被覆盖
Post-dispatch     → mr_timerStart(50)    → api_timer_due_ms = now + 50
```

之后 worker 线程每 50ms 触发一次 `mr_timer()`，MRP 应用的 1000ms 间隔被缩至 50ms。

### 对比 arm_ext_call

`arm_ext_call` 中的所有 `mr_timerStart(50)` **都有** `!m->host_timer_pending` 前置条件：

```c
// arm_ext_call 中（正确）
if (code == 2 && !m->host_timer_pending && ...) {
    mr_timerStart(50);   // 只在 ARM 侧未设 timer 时补启
}
```

但 `arm_ext_call_dispatch` 中的两处 `mr_timerStart((uint16)timer_interval)` **缺少**此检查。

## 修复方案

**CMake patch: OHOS_TIMER_NO_OVERRIDE**

在 `arm_ext_call_dispatch`（`arm_ext_executor.c`，未拆分）的两处 `mr_timerStart` 调用前，检查 `sync_timer_state_from_arm` 后的 `m->host_timer_pending`：

- `host_timer_pending == 1`：ARM 侧已通过 `table[31]` 设了自己的 timer interval，**不覆盖**
- `host_timer_pending == 0`：ARM 侧未设 timer，补启 50ms tick 驱动 wrapper queue

> **注意**: `arm_ext_call_dispatch` 仍留在 `arm_ext_executor.c`（line 2026），未随 Phase 0-5 重构拆分。
> `run_arm_with_sp` 和堆数据恢复已拆到 `aex_exec.c`，但 dispatch 和 timer 逻辑仍在本文件。

### 第一处：wrapper_timer_owner + queue_live

```c
// 修复前
if (queue_live) {
    mr_timer_state = 1;
    m->host_timer_pending = 1;
    internal_slot_write(m, m->mr_timer_state_slot, 1);
    mr_timerStart((uint16)timer_interval);   // 无条件覆盖
    ...
}

// 修复后
if (queue_live) {
    int _arm_set_timer = m->host_timer_pending;  // OHOS_TIMER_NO_OVERRIDE
    mr_timer_state = 1;
    m->host_timer_pending = 1;
    internal_slot_write(m, m->mr_timer_state_slot, 1);
    if (!_arm_set_timer) {
        mr_timerStart((uint16)timer_interval);   // 只在 ARM 未设 timer 时补启
    }
    ...
}
```

### 第二处：chain_walker_owner + tc_after

```c
// 修复前
if (tc_after) {
    mr_timer_state = 1;
    m->host_timer_pending = 1;
    internal_slot_write(m, m->mr_timer_state_slot, 1);
    mr_timerStart((uint16)timer_interval);   // 无条件覆盖
}

// 修复后
if (tc_after) {
    int _arm_set_timer_cw = m->host_timer_pending;  // OHOS_TIMER_NO_OVERRIDE
    mr_timer_state = 1;
    m->host_timer_pending = 1;
    internal_slot_write(m, m->mr_timer_state_slot, 1);
    if (!_arm_set_timer_cw) {
        mr_timerStart((uint16)timer_interval);   // 只在 ARM 未设 timer 时补启
    }
}
```

## host_timer_pending 状态分析

`sync_timer_state_from_arm()` 在 `run_arm_with_sp()`（`aex_exec.c`）之后执行，可能修改 `host_timer_pending`：

| ARM 行为 | arm_timer_state | sync 后 host_timer_pending | _arm_set_timer | 补启? |
|----------|----------------|---------------------------|----------------|-------|
| 调 table[31] 未调 table[32] | 1 (RUNNING) | 1（sync 不清） | 1 | 否 ✅ |
| 调 table[31] 后又调 table[32] | 0 (IDLE) | 0（sync 清零） | 0 | 是 ✅ |
| 未调 table[31] | 0 (IDLE) | 0（sync 清零） | 0 | 是 ✅ |

三种场景均正确：ARM 侧设了 timer 不覆盖，ARM 侧没设则补启。

## 配置行

CMake configure 输出：
```
-- [OHOS] Patched arm_ext_call_dispatch mr_timerStart no-override (OHOS_TIMER_NO_OVERRIDE)
```
