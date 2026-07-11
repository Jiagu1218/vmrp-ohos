# 震动（Vibrator）适配文档

## 概述

本文档记录 vmrp-ohos 项目中 MRP 震动接口 `mr_startShake(ms)` / `mr_stopShake()`
到 HarmonyOS Vibrator C 原生 API 的适配实现，以及震动强度三档设置的实现方式。

MRP 震动 API 对应 `mr_startShake(int32 ms)`（启动震动，持续 ms 毫秒）和
`mr_stopShake()`（停止震动），参考 gddhy.net SkyEngine 官方文档的"输出接口"章节。

## 适配架构

```
MRP 应用调 mr_startShake(ms)
    ↓
dsm.c  mr_startShake(ms) → dsmInFuncs->mr_startShake(ms)
    ↓
native_dsm_funcs.c  native_startShake(ms)
    ↓ extern vmrp_api_start_shake(ms)
vmrp_api.c  vmrp_api_start_shake(ms)
    ↓ 回调
vmrp_engine.cpp  shake_start_cb(ms)
    ↓ 根据强度缩放 duration + 选择 usage
OH_Vibrator_PlayVibration(adjusted_ms, attr)

MRP 应用调 mr_stopShake()
    ↓
dsm.c  mr_stopShake() → dsmInFuncs->mr_stopShake()
    ↓
native_dsm_funcs.c  native_stopShake()
    ↓ extern vmrp_api_stop_shake()
vmrp_api.c  vmrp_api_stop_shake()
    ↓ 回调
vmrp_engine.cpp  shake_stop_cb()
    ↓
OH_Vibrator_Cancel()
```

## 关键设计决策

### 1. C 原生 API 选用

**问题**：HarmonyOS 提供两套振动 API：
- C 原生 API：`OH_Vibrator_PlayVibration(duration, attribute)` / `OH_Vibrator_Cancel()`
  — 头文件 `<sensors/vibrator.h>`，链接 `libohvibrator.z.so`
- ArkTS API：`vibrator.startVibration({type:'preset', effectId, count, intensity}, {usage})`
  — 支持 `intensity` 参数（0~100），但需要设备支持 HD Haptic

**选择**：C 原生 API。理由：
- 与传感器（OH_Sensor）实现保持一致，全链路 C/C++，无需 NAPI threadsafe function
- `OH_Vibrator_PlayVibration` 在 API 11 即可用，兼容性更好
- `Vibrator_Attribute` 结构体只有 `vibratorId` 和 `usage` 两个字段，无 `intensity`
- 强度差异通过 `duration` 缩放 + `usage` 切换模拟（见决策 2）

### 2. 震动强度三档模拟

**问题**：C 原生 API 没有 `intensity` 参数，无法直接控制振幅。

**解决方案**：通过 `duration` 缩放和 `Vibrator_Usage` 切换模拟三档强度：

| 档位 | level | duration 缩放 | usage | 效果描述 |
|------|-------|---------------|-------|----------|
| 轻柔 | 0 | `max(50, ms × 0.3)` | `VIBRATOR_USAGE_TOUCH` | 短振，触觉反馈级别 |
| 适中 | 1 | `ms × 1.0` | `VIBRATOR_USAGE_TOUCH` | MRP 原始时长，默认 |
| 强烈 | 2 | `ms × 2.0` | `VIBRATOR_USAGE_ALARM` | 长振+闹钟优先级，更醒目 |

**实现**：在 C++ shake 回调中根据 `VmrpEngine::Instance().GetShakeIntensity()` 计算。

**为什么不选 ArkTS preset 模式**：虽然 ArkTS `VibratePreset` 支持 `intensity`（0~100），
但需要：
1. NAPI threadsafe function 从 C++ 回调到 ArkTS 线程
2. `isHdHapticSupported()` 设备检测，不支持时仍需 fallback
3. 复杂度远高于 C 原生方案，收益有限（MRP 震动场景简单，三档足够）

### 3. 回调模式（与 motion_power 一致）

**设计**：与动感芯片上电/断电回调采用相同模式：
- `vmrp_api_set_shake_cb(start_cb, stop_cb)` — 宿主注册回调
- `vmrp_api_start_shake(ms)` — `native_startShake` 调用，触发 `start_cb`
- `vmrp_api_stop_shake()` — `native_stopShake` 调用，触发 `stop_cb`

**依赖方向**：`native_dsm_funcs.c` → `vmrp_api_start_shake()`（libvmrp.so 导出）→ 注册的回调 → `libentry.so`

**幂等标记**：CMake 补丁用 `OHOS_SHAKE` 标记保证幂等。

## vmrp C 核心层修改清单

### 1. vmrp_api.c — 宿主 API 入口

**文件**：`vmrp/src/vmrp_api.c`（CMake 补丁注入，幂等标记 `OHOS_SHAKE`）

**新增导出函数**：

```c
/* OHOS_SHAKE: 震动回调 */
static void (*shake_start_cb)(int ms) = NULL;
static void (*shake_stop_cb)(void) = NULL;

VMRP_EXPORT void vmrp_api_start_shake(int ms) {
    if (shake_start_cb) shake_start_cb(ms);
}

VMRP_EXPORT void vmrp_api_stop_shake(void) {
    if (shake_stop_cb) shake_stop_cb();
}

VMRP_EXPORT void vmrp_api_set_shake_cb(void (*start)(int ms), void (*stop)(void)) {
    shake_start_cb = start;
    shake_stop_cb = stop;
}
```

> 注意：vmrp_api.c 在 `:restore_patched` 列表中，修改以 CMake 补丁形式注入，
> 构建后恢复为 git 提交状态。

---

### 2. native_dsm_funcs.c — 原生实现改写

**文件**：`vmrp/src/native_dsm_funcs.c`（CMake 补丁注入，幂等标记 `OHOS_SHAKE`）

**改写前**（空实现）：

```c
static int32 native_startShake(int32 ms) {
    (void)ms;
    return MR_SUCCESS;
}

static int32 native_stopShake(void) {
    return MR_SUCCESS;
}
```

**改写后**：

```c
/* OHOS_SHAKE: 转发 MRP 震动请求到宿主(vmrp_api_start_shake),
 * 由宿主调 OH_Vibrator C API。 */
static int32 native_startShake(int32 ms) {
    extern void vmrp_api_start_shake(int ms);
    vmrp_api_start_shake(ms);
    return MR_SUCCESS;
}

static int32 native_stopShake(void) {
    extern void vmrp_api_stop_shake(void);
    vmrp_api_stop_shake();
    return MR_SUCCESS;
}
```

---

### 3. scripts/CMakeLists.txt — 构建补丁

#### 3.1 vmrp_api.c 补丁（追加到 motion 补丁段）

子补丁3：在 `vmrp_api_set_motion_sensitivity` 后追加震动回调导出函数，
幂等标记 `OHOS_SHAKE`。

#### 3.2 native_dsm_funcs.c 补丁

将原有的单独 MAP_32BIT 补丁扩展为 MAP_32BIT + OHOS_SHAKE 双补丁，
共用同一个 `if(EXISTS)` 块。

---

## HarmonyOS 应用层修改清单

### 1. module.json5 — 权限声明

**文件**：`entry/src/main/module.json5`

`ohos.permission.VIBRATE` 权限已在之前版本声明（用于按键震动反馈），
无需新增。

---

### 2. vmrp_engine.h — C++ 引擎接口

**文件**：`entry/src/main/cpp/vmrp_engine.h`

**新增**：

```cpp
struct VmrpApi {
    ...
    void (*set_shake_cb)(void (*start)(int ms), void (*stop)(void));  // 新增
};

class VmrpEngine {
    ...
    void SetShakeIntensity(int level);    // 新增：0=轻,1=中(默认),2=强
    int GetShakeIntensity() const;         // 新增
    ...
private:
    int shake_intensity_ = 1;              // 新增
};
```

---

### 3. vmrp_engine.cpp — 引擎实现

**文件**：`entry/src/main/cpp/vmrp_engine.cpp`

#### 3.1 新增 include

```cpp
#include <sensors/vibrator.h>
```

#### 3.2 dlsym 解析新符号

```cpp
RESOLVE_SYM(so_handle_, "vmrp_api_set_shake_cb", set_shake_cb,
            void (*)(void (*)(int), void (*)(void)));
```

#### 3.3 注册震动回调

```cpp
if (api_.set_shake_cb) {
    api_.set_shake_cb(
        [](int ms) {
            int level = VmrpEngine::Instance().GetShakeIntensity();
            int32_t duration = ms > 0 ? ms : 200;
            Vibrator_Usage usage = VIBRATOR_USAGE_TOUCH;
            if (level == 0) {
                duration = std::max(50, duration * 3 / 10);
            } else if (level == 2) {
                duration = duration * 2;
                usage = VIBRATOR_USAGE_ALARM;
            }
            Vibrator_Attribute attr;
            attr.vibratorId = 0;
            attr.usage = usage;
            int32_t ret = OH_Vibrator_PlayVibration(duration, attr);
            if (ret != 0) {
                OH_LOG_INFO(LOG_APP, "OH_Vibrator_PlayVibration failed: %{public}d", ret);
            }
        },
        []() {
            int32_t ret = OH_Vibrator_Cancel();
            if (ret != 0) {
                OH_LOG_INFO(LOG_APP, "OH_Vibrator_Cancel failed: %{public}d", ret);
            }
        }
    );
    LOGI("shake callback registered (OH_Vibrator C API)");
}
```

#### 3.4 震动强度设置

```cpp
void VmrpEngine::SetShakeIntensity(int level) {
    if (level < 0) level = 0;
    if (level > 2) level = 2;
    shake_intensity_ = level;
}
```

---

### 4. CMakeLists.txt — 链接 libohvibrator.z.so

**文件**：`entry/src/main/cpp/CMakeLists.txt`

**变更**：

```cmake
target_link_libraries(vmrp_entry PUBLIC
    ...
    libohvibrator.z.so    # OH_Vibrator 振动马达 C 原生 API
)
```

---

### 5. vmrp_napi.cpp — N-API 绑定

**文件**：`entry/src/main/cpp/vmrp_napi.cpp`

**新增**：

```cpp
static napi_value SetShakeIntensity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t level = 1;
    napi_get_value_int32(env, args[0], &level);
    VmrpEngine::Instance().SetShakeIntensity(level);
    return nullptr;
}

// 注册
{"setShakeIntensity", nullptr, SetShakeIntensity, nullptr, nullptr, nullptr, napi_default, nullptr},
```

---

### 6. Index.d.ts — TypeScript 类型声明

**文件**：`entry/src/main/cpp/types/libentry/Index.d.ts`

**新增**：

```typescript
export const setShakeIntensity: (level: number) => void;
```

---

### 7. VmrpEngine.ets — ETS 引擎封装

**文件**：`entry/src/main/ets/vmrp/VmrpEngine.ets`

**新增**：

```typescript
import { setShakeIntensity as nativeSetShakeIntensity, ... } from 'libentry.so';

export class VmrpEngineTs {
    setShakeIntensity(level: number): void {
        nativeSetShakeIntensity(level);
    }
}
```

---

### 8. Index.ets — 启动时加载强度设置

**文件**：`entry/src/main/ets/pages/Index.ets`

**新增**：bootstrap 时从 preferences 读取震动强度并传入 C 层：

```typescript
const shakeIntensity = (await pref.get('shake_intensity', 1)) as number;
this.engine.setShakeIntensity(shakeIntensity);
```

---

### 9. Settings.ets — 游戏震动设置 UI

**文件**：`entry/src/main/ets/pages/Settings.ets`

**新增**："游戏震动"设置分组，包含强度选择器：

- 三档选择：轻柔(0) / 适中(1) / 强烈(2)，默认适中
- 持久化到 `vmrp_settings` preferences，key `shake_intensity`
- 即时生效（无需重启游戏）
- 与"按键震动"（UI 触觉反馈，`HapticManager`）独立控制

**与按键震动的区别**：

| 特性 | 按键震动 | 游戏震动 |
|------|----------|----------|
| 触发源 | ArkTS UI 按键回调 | MRP `mr_startShake(ms)` |
| API | ArkTS `vibrator.startVibration({type:'preset'})` | C `OH_Vibrator_PlayVibration()` |
| 强度控制 | preset effectId（light/medium/heavy） | duration 缩放 + usage 切换 |
| 持久化 key | `haptic_enabled` / `haptic_strength` | `shake_intensity` |
| 生效时机 | 即时 | 即时 |

---

## SkyEngine 震动 API 对照

| SkyEngine API | 签名 | vmrp-ohos 实现 |
|---------------|------|----------------|
| `mr_startShake(ms)` | `int32 mr_startShake(int32 ms)` | `native_startShake` → `vmrp_api_start_shake` → `OH_Vibrator_PlayVibration` |
| `mr_stopShake()` | `int32 mr_stopShake()` | `native_stopShake` → `vmrp_api_stop_shake` → `OH_Vibrator_Cancel` |

---

## 日志观察

真机运行时 hilog 中的关键日志：

| 日志 | 标签 | 含义 |
|------|------|------|
| `shake callback registered (OH_Vibrator C API)` | `vmrp_engine` | 震动回调注册成功 |
| `OH_Vibrator_PlayVibration failed: %{public}d` | `vmrp_engine` | 振动启动失败（权限/设备不支持） |
| `OH_Vibrator_Cancel failed: %{public}d` | `vmrp_engine` | 停止振动失败 |
| `shake intensity set to %{public}d` | `vmrp_engine` | 强度设置变更 |

---

## 已知限制

1. **C 原生 API 无 intensity 参数**：`OH_Vibrator_PlayVibration` 只有 `duration`
   和 `usage`，无法精确控制振幅。当前通过 duration 缩放 + usage 切换模拟三档强度，
   实际振感差异取决于设备马达硬件和系统触感映射。

2. **VIBRATOR_USAGE_ALARM 的影响**：强烈模式使用 `VIBRATOR_USAGE_ALARM`，
   在某些设备上可能受"闹钟音量"开关控制，而非"触感"开关。
   如果用户关闭闹钟振动，强烈档可能不振动。

3. **不支持自定义振动模式**：ArkTS API 支持 `VibrateFromFile`（自定义 JSON
   振动序列）和 `VibrateFromPattern`，C 原生 API 的 `OH_Vibrator_PlayVibrationCustom`
   也支持，但 vmrp-ohos 当前未使用。MRP 的 `mr_startShake(ms)` 只有时长参数，
   无振动模式需求。

4. **ms=0 边界**：MRP 传入 `ms=0` 时，默认使用 200ms 时长，避免零时长无效振动。

---

## 修改文件汇总

### vmrp C 核心（CMake 补丁注入，构建后恢复）

| 文件 | 补丁内容 | 幂等标记 |
|------|----------|----------|
| `vmrp/src/vmrp_api.c` | 新增 `vmrp_api_start_shake/stop_shake/set_shake_cb` | `OHOS_SHAKE` |
| `vmrp/src/native_dsm_funcs.c` | `native_startShake/stopShake` 转发到 vmrp_api | `OHOS_SHAKE` |

### HarmonyOS 应用层

| 文件 | 变更 |
|------|------|
| `entry/src/main/cpp/CMakeLists.txt` | 新增 `libohvibrator.z.so` 链接 |
| `entry/src/main/cpp/vmrp_engine.h` | 新增 `set_shake_cb` 指针 + `SetShakeIntensity/GetShakeIntensity` + `shake_intensity_` |
| `entry/src/main/cpp/vmrp_engine.cpp` | 新增 `<sensors/vibrator.h>` + dlsym 解析 + 回调注册（含强度缩放）+ `SetShakeIntensity` |
| `entry/src/main/cpp/vmrp_napi.cpp` | 新增 `SetShakeIntensity` N-API 函数 + 注册 |
| `entry/src/main/cpp/types/libentry/Index.d.ts` | 新增 `setShakeIntensity` 类型声明 |
| `entry/src/main/ets/vmrp/VmrpEngine.ets` | 新增 `setShakeIntensity` 封装 |
| `entry/src/main/ets/pages/Index.ets` | 启动时从 preferences 读取 `shake_intensity` |
| `entry/src/main/ets/pages/Settings.ets` | 新增"游戏震动"分组：强度选择器（轻柔/适中/强烈） |
