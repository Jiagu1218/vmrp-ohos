# 动感芯片（重力感应）适配文档

## 概述

本文档记录 vmrp-ohos 项目中 MRP 动感芯片（重力感应/加速度传感器）的完整适配过程，
涵盖从 HarmonyOS 传感器 C 原生 API 到 MRP Mythroad SDK 的全链路实现。

MRP 动感芯片 API 对应 `mr_plat(4001~4006)` 和 `MR_MOTION_EVENT` 事件，
参考 gddhy.net SkyEngine 官方文档。

## 适配架构总览

```
MRP 应用调 mr_plat(4002) 上电
    ↓
dsm.c  mr_plat(4002) → vmrp_api_motion_power(1)
    ↓ 回调
vmrp_engine.cpp  StartSensor()
    ↓ OH_Sensor_Subscribe(SENSOR_TYPE_ACCELEROMETER)
HarmonyOS 传感器回调 OnAccelerometerData()
    ↓ m/s² → mG (×102) + Y轴取反 + 灵敏度倍率
    ↓ SendMotion(xMg, yMg, zMg)
    ↓ dlsym → vmrp_api_motion_event()
vmrp_api.c  vmrp_api_motion_event()
    ↓ dsm_set_motion_acc()  仅缓存
    ↓ API_CMD_MOTION 入队
═══════════ 进程边界（队列） ═══════════
    ↓ worker 线程消费 API_CMD_MOTION
dsm.c  dsm_dispatch_motion_event()
    ↓ dsm_write_motion_acc_to_arm()  ← mythroad.c 桥接函数
    ↓   dsm_get_motion_acc()         ← 读取缓存
    ↓   arm_ext_write_motion_acc()   ← 写入 Unicorn VM 内存
    ↓   返回 ARM 可见 32 位地址 (如 0x002259C0)
    ↓ mr_event(MR_MOTION_EVENT, mode, arm_addr)
mythroad.c  mr_event()
    ↓ native_ext_callback3(func, type, param1, arm_addr)
ARM EXT 代码  dealevent(MR_MOTION_EVENT, mode, addr)
    ↓ LDR r0, [r2]    读取 T_MOTION_ACC.x
    ↓ LDR r1, [r2+4]  读取 T_MOTION_ACC.y
    ↓ LDR r2, [r2+8]  读取 T_MOTION_ACC.z

MRP 应用调 mr_plat(4003) 断电
    ↓
dsm.c  mr_plat(4003) → vmrp_api_motion_power(0)
    ↓ 回调
vmrp_engine.cpp  StopSensor()
    ↓ OH_Sensor_Unsubscribe()
传感器停止上报
```

## 关键设计决策

### 1. 传感器管理在 C 层（OH_Sensor 原生 API）

**问题**：早期实现将传感器订阅放在 ETS 层（`sensor.on`/`sensor.off`），
存在两个问题：
- 传感器在游戏启动后始终订阅，不受 MRP 上电/断电控制，浪费电量
- 数据需 ETS→NAPI→C 跨层传递，增加延迟和复杂度

**解决方案**：
- 使用 HarmonyOS C 原生传感器 API（`OH_Sensor_Subscribe`/`Unsubscribe`，
  头文件 `<sensors/oh_sensor.h>`，链接 `libohsensor.so`）
- 传感器回调直接在 C 层完成 m/s²→mG 转换 + Y 轴取反 + 灵敏度倍率，
  然后调 `SendMotion()`，无需绕道 ETS
- MRP 上电/断电通过回调机制控制传感器启停（见决策 2）

**相关文件**：
- `entry/src/main/cpp/vmrp_engine.cpp`：`StartSensor()`/`StopSensor()`/`OnAccelerometerData()`
- `entry/src/main/cpp/CMakeLists.txt`：链接 `libohsensor.so`

### 2. 上电/断电回调驱动传感器启停

**问题**：MRP 的动感芯片 API 要求上电（mr_plat 4002）时才开始采集传感器数据，
断电（mr_plat 4003）时停止。但 `dsm.c` 在 `libvmrp.so` 内部，
传感器管理在 `libentry.so`，依赖方向不能反过来。

**解决方案**：回调注册模式：
- `vmrp_api_set_motion_power_cb(cb)` — `libentry.so` 在 `Load()` 时注册回调
- `vmrp_api_motion_power(on)` — `dsm.c` 在 mr_plat(4002/4003) 时调用
- 回调在 `libentry.so` 中实现，调用 `StartSensor()`/`StopSensor()`

**依赖方向**：`dsm.c` → `vmrp_api_motion_power()`（libvmrp.so 导出）→ 注册的回调 → `libentry.so`

**相关文件**：
- `vmrp/src/include/vmrp_api.h`：`vmrp_motion_power_cb` 类型 + 3 个导出函数声明
- `vmrp/src/vmrp_api.c`：全局回调指针 + 导出函数实现
- `vmrp/src/mythroad/dsm.c`：mr_plat(4002/4003) 调用 `vmrp_api_motion_power()`
- `entry/src/main/cpp/vmrp_engine.cpp`：注册回调 + `StartSensor()`/`StopSensor()`

### 3. Y 轴方向取反

**问题**：HarmonyOS 加速度传感器坐标系 Y 轴正方向朝上（设备顶部），
而 MRP 游戏使用屏幕坐标系 Y 轴正方向朝下。
设备往上抬时传感器 Y 为正，但游戏期望球往下滚（Y 正方向朝下），
方向相反。

**解决方案**：Y 轴取反 `yMg = -round(data.y * 102 * sensitivity)`

**坐标系对照**：
- HarmonyOS 传感器：X=右, Y=上, Z=屏幕正面朝外
- MRP 屏幕：X=右, Y=下
- 因此仅 Y 需取反，X 和 Z 方向一致

### 4. 异步队列投递（非直接 mr_event 调用）

**问题**：传感器回调运行在 HarmonyOS 传感器专有线程，
而 Unicorn 引擎在同一时刻只能被一个线程访问。
如果在传感器回调中直接调用 `mr_event()` → `uc_emu_start()`，
会导致 Unicorn 并发访问，触发 SIGBUS 崩溃。

**解决方案**：传感器回调仅调用 `dsm_set_motion_acc()` 缓存三轴数据，
然后通过 `API_CMD_MOTION` 命令入队。VMRP worker 线程消费队列时
才调用 `dsm_dispatch_motion_event()` → `mr_event()`，
保证 Unicorn 串行执行。

### 5. Unicorn 虚拟内存中的 T_MOTION_ACC（64 位指针截断修复）

**问题**：`mr_event(MR_MOTION_EVENT, mode, param2)` 的 param2 是一个指针，
指向 `T_MOTION_ACC{x, y, z}` 结构体。在真机 32 位 ARM 环境下，
`&motion_acc` 是有效的 32 位地址。但在 Unicorn 模拟环境中：

- Unicorn 模拟的是 32 位 ARM 地址空间（0x10000 ~ 0x1000000）
- 宿主变量 `&motion_acc` 是 64 位主机地址（如 0x7FFF12345678）
- `(int32)(uintptr_t)&motion_acc` 截断高 32 位 → ARM 代码解引用无效地址 → SIGBUS

**解决方案**：在 Unicorn 虚拟内存中分配 12 字节（3×int32）作为 T_MOTION_ACC 缓冲区：
- `ArmExtModule.motion_acc_addr`：Unicorn VM 地址（如 0x002259C0）
- `arm_ext_write_motion_acc()`：将 x/y/z 写入 Unicorn 内存，返回 VM 地址
- `dsm_write_motion_acc_to_arm()`：桥接函数，从 dsm.c 读取缓存，写入 Unicorn，返回 VM 地址

### 6. SendMotion 不持 engine_mtx_

**问题**：`SendEvent()` 持 `engine_mtx_`，而 `vmrp_api_event()` 内部持 `api_lock`。
如果 `SendMotion()` 也持 `engine_mtx_`，而 worker 线程在某些路径下
先获 `engine_mtx_` 再获 `api_lock`，就会产生死锁。

**解决方案**：`SendMotion()` 不持 `engine_mtx_`。因为 `vmrp_api_motion_event()`
只做缓存+入队（持 `api_lock`），不同步调用 Unicorn，无并发风险。

### 7. 灵敏度设置

**实现**：
- `vmrp_api_set_motion_sensitivity(float)` — 设置全局灵敏度倍率（默认 1.0）
- 传感器回调中 `yMg = -round(data.y * 102 * sensitivity)`
- ETS 侧从 preferences 读取用户设置值，通过 `setMotionSensitivity()` 传入 C 层
- 设置页面提供 0.2x ~ 3.0x 滑块

## vmrp C 核心层修改清单

### 1. mrporting.h — 事件码和模式枚举

**文件**：`vmrp/src/mythroad/include/mrporting.h`

**变更**：在 `MR_MOTION_EVENT` 之后新增动感芯片子类型枚举

```c
enum {
    MR_MOTION_EVENT,
};

/* 动感芯片事件子类型（mr_event p2 / mr_plat 4004/4005 mode） */
enum {
    MR_MOTION_EVENT_SHAKE = 0,  // 晃动模式
    MR_MOTION_EVENT_TILT  = 1,  // 倾斜模式
};
```

---

### 2. dsm.c — 动感芯片平台接口实现

**文件**：`vmrp/src/mythroad/dsm.c`

#### 2.1 全局状态变量

```c
static int motion_enabled = 0;  /* mr_plat(4004/4005)=1, 4001=0 */
static int motion_mode = 0;     /* MR_MOTION_EVENT_SHAKE(0) / TILT(1) */
static int motion_powered = 0;  /* mr_plat(4002)=1, 4003=0 */
static struct { int32 x; int32 y; int32 z; } motion_acc = {0, 0, 1000};
```

#### 2.2 dsm_set_motion_acc() — 宿主写入加速度

```c
void dsm_set_motion_acc(int32 x, int32 y, int32 z);
```

- **线程安全**：仅写入 3 个 int32，ARM64 上天然原子，无需加锁
- **不调 mr_event**：避免 Unicorn 并发

#### 2.3 dsm_get_motion_acc() — 读取缓存

```c
void dsm_get_motion_acc(int32 *x, int32 *y, int32 *z);
```

供 `mythroad.c` 的 `dsm_write_motion_acc_to_arm()` 调用。

#### 2.4 dsm_dispatch_motion_event() — 投递事件

```c
void dsm_dispatch_motion_event(void) {
    if (motion_enabled) {
        uint32 arm_addr = dsm_write_motion_acc_to_arm();
        if (!arm_addr) return;
        mr_event(MR_MOTION_EVENT, motion_mode, (int32)arm_addr);
    }
}
```

#### 2.5 mr_plat() 新增 case 4001~4006

| code | 功能 | 实现说明 |
|------|------|----------|
| 4001 | 停止监听 | `motion_enabled = 0` |
| 4002 | 上电 | `motion_powered = 1` + 调 `vmrp_api_motion_power(1)` 通知宿主开启传感器 |
| 4003 | 断电 | `motion_powered = 0; motion_enabled = 0` + 调 `vmrp_api_motion_power(0)` 通知宿主停止传感器 |
| 4004 | 晃动模式 | `motion_enabled = 1; motion_mode = MR_MOTION_EVENT_SHAKE` |
| 4005 | 倾斜模式 | `motion_enabled = 1; motion_mode = MR_MOTION_EVENT_TILT` |
| 4006 | 获取范围 | 返回 3000，表示 ±2000mG（= ±2g） |

4002/4003 上电/断电时通过 `extern void vmrp_api_motion_power(int on)` 调用
libvmrp.so 导出函数，该函数内部调用宿主注册的回调来启停传感器。

---

### 3. dsm.h — 头文件声明

**文件**：`vmrp/src/mythroad/include/dsm.h`

**新增声明**：

```c
void dsm_set_motion_acc(int32 x, int32 y, int32 z);
void dsm_get_motion_acc(int32 *x, int32 *y, int32 *z);
uint32 dsm_write_motion_acc_to_arm(void);
void dsm_dispatch_motion_event(void);
```

---

### 4. vmrp_api.c — 宿主 API 入口

**文件**：`vmrp/src/vmrp_api.c`

#### 4.1 新增 API_CMD_MOTION 命令类型

```c
typedef enum {
    API_CMD_EVENT,
    API_CMD_SET_EDIT_TEXT,
    API_CMD_CANCEL_EDIT,
    API_CMD_MOTION,
} ApiCommandType;
```

#### 4.2 vmrp_api_motion_event() — 导出函数

```c
VMRP_EXPORT int vmrp_api_motion_event(int x_mg, int y_mg, int z_mg);
```

异步路径（`VMRP_API_ASYNC_RUNNER=1`）：
1. `dsm_set_motion_acc(x_mg, y_mg, z_mg)` — 仅缓存
2. `api_queue_command(API_CMD_MOTION)` — 入队
3. worker 线程消费 → `dsm_dispatch_motion_event()` → `mr_event()`

#### 4.3 动感芯片上电/断电回调

```c
static vmrp_motion_power_cb g_motion_power_cb = NULL;
static float g_motion_sensitivity = 1.0f;

VMRP_EXPORT void vmrp_api_set_motion_power_cb(vmrp_motion_power_cb cb);
VMRP_EXPORT void vmrp_api_motion_power(int on);
VMRP_EXPORT void vmrp_api_set_motion_sensitivity(float sensitivity);
```

- `vmrp_api_set_motion_power_cb()` — 宿主注册回调（`libentry.so` 在 `Load()` 时调用）
- `vmrp_api_motion_power()` — `dsm.c` 的 mr_plat(4002/4003) 调用，触发注册的回调
- `vmrp_api_set_motion_sensitivity()` — 设置灵敏度倍率（>0 有效）

#### 4.4 worker 线程新增 API_CMD_MOTION 分支

```c
case API_CMD_MOTION:
    dsm_dispatch_motion_event();
    break;
```

---

### 5. vmrp_api.h — 宿主 API 声明

**文件**：`vmrp/src/include/vmrp_api.h`

**新增**：

```c
typedef void (*vmrp_motion_power_cb)(int on);
VMRP_EXPORT int vmrp_api_motion_event(int x_mg, int y_mg, int z_mg);
VMRP_EXPORT void vmrp_api_set_motion_power_cb(vmrp_motion_power_cb cb);
VMRP_EXPORT void vmrp_api_motion_power(int on);
VMRP_EXPORT void vmrp_api_set_motion_sensitivity(float sensitivity);
```

---

### 6. arm_ext_internal.h — ArmExtModule 结构体扩展

**文件**：`vmrp/src/include/arm_ext_internal.h`

**新增字段**：

```c
struct ArmExtModule {
    ...
    uint32_t motion_acc_addr;  // T_MOTION_ACC 缓冲区 Unicorn VM 地址
    ...
};
```

**分配时机**：`arm_ext_load()` → `init_table()` 中：

```c
write_table_entry(m, 91, alloc_u32_slot(m, m->screen_addr));
m->motion_acc_addr = arm_alloc(m, 12);  // 12 = 3×sizeof(int32)
```

---

### 7. arm_ext_executor.h — 公共 API 扩展

**文件**：`vmrp/src/include/arm_ext_executor.h`

**新增声明**：

```c
uint32_t arm_ext_write_motion_acc(ArmExtModule *m, int32 x, int32 y, int32 z);
```

**实现**（通过 CMake 补丁注入 `arm_ext_executor.c`）：

```c
uint32_t arm_ext_write_motion_acc(ArmExtModule *m, int32 x, int32 y, int32 z) {
    if (!m || !m->motion_acc_addr) return 0;
    int32 data[3] = {x, y, z};
    void *dst = arm_ptr(m, m->motion_acc_addr);
    if (!dst) return 0;
    memcpy(dst, data, sizeof(data));
    return m->motion_acc_addr;
}
```

---

### 8. mythroad.c — 桥接函数（CMake 补丁注入）

**文件**：`vmrp/src/mythroad/mythroad.c`（通过 `scripts/CMakeLists.txt` 补丁）

> 注意：`mythroad.c` 在 `:restore_patched` 列表中，构建后恢复为 git 提交状态，
> 修改以 CMake 补丁形式注入，幂等标记 `OHOS_MOTION_ACC_BRIDGE`。

**新增函数**：

```c
extern void dsm_get_motion_acc(int32 *x, int32 *y, int32 *z);

uint32 dsm_write_motion_acc_to_arm(void) {
    if (!native_ext) return 0;
    int32 x = 0, y = 0, z = 0;
    dsm_get_motion_acc(&x, &y, &z);
    return arm_ext_write_motion_acc(native_ext, x, y, z);
}
```

---

### 9. scripts/CMakeLists.txt — 构建补丁

**新增两个补丁段**：

#### 9.1 arm_ext_executor.c 补丁（幂等标记：`arm_ext_write_motion_acc`）

Step 1 — 在 `write_table_entry(m, 91, ...)` 后分配 `motion_acc_addr`
Step 2 — 在 `arm_ext_unload()` 之前插入 `arm_ext_write_motion_acc()` 实现

#### 9.2 mythroad.c 补丁（幂等标记：`OHOS_MOTION_ACC_BRIDGE`）

在 `mr_event()` 之前插入 `dsm_write_motion_acc_to_arm()` 函数定义。

---

## HarmonyOS 应用层修改清单

### 1. module.json5 — 权限声明

**文件**：`entry/src/main/module.json5`

**新增**：

```json5
{
  "name": "ohos.permission.ACCELEROMETER",
  "reason": "$string:permission_accelerometer_reason",
  "usedScene": {
    "abilities": ["EntryAbility"],
    "when": "inuse"
  }
}
```

---

### 2. vmrp_engine.h — C++ 引擎接口

**文件**：`entry/src/main/cpp/vmrp_engine.h`

**变更**：

```cpp
struct VmrpApi {
    ...
    int (*motion_event)(int x_mg, int y_mg, int z_mg);
    void (*set_motion_power_cb)(void (*cb)(int on));   // 新增
    void (*set_motion_sensitivity)(float sensitivity); // 新增
    ...
};

class VmrpEngine {
    ...
    int SendMotion(int x, int y, int z);
    void StartSensor();              // 新增：OH_Sensor 订阅
    void StopSensor();               // 新增：OH_Sensor 取消订阅
    void SetMotionSensitivity(float s); // 新增：设置灵敏度
    float GetMotionSensitivity() const;
    ...
private:
    bool sensor_subscribed_ = false;    // 新增
    float motion_sensitivity_ = 1.0f;   // 新增
};
```

---

### 3. vmrp_engine.cpp — 引擎实现

**文件**：`entry/src/main/cpp/vmrp_engine.cpp`

**核心变更**：

#### 3.1 新增 include

```cpp
#include <sensors/oh_sensor.h>
```

#### 3.2 dlsym 解析新符号

```cpp
RESOLVE_SYM(so_handle_, "vmrp_api_set_motion_power_cb", set_motion_power_cb, void (*)(void (*)(int)));
RESOLVE_SYM(so_handle_, "vmrp_api_set_motion_sensitivity", set_motion_sensitivity, void (*)(float));
```

#### 3.3 注册上电/断电回调

```cpp
// Load() 成功后
if (api_.set_motion_power_cb) {
    api_.set_motion_power_cb([](int on) {
        if (on) VmrpEngine::Instance().StartSensor();
        else VmrpEngine::Instance().StopSensor();
    });
}
```

#### 3.4 OH_Sensor 传感器管理

```cpp
namespace {
Sensor_SubscriptionId *g_sensor_sub_id = nullptr;
Sensor_SubscriptionAttribute *g_sensor_sub_attr = nullptr;
Sensor_Subscriber *g_sensor_subscriber = nullptr;

void OnAccelerometerData(Sensor_Event *event) {
    float *data = nullptr;
    uint32_t len = 0;
    if (OH_SensorEvent_GetData(event, &data, &len) != SENSOR_SUCCESS || !data || len < 3) return;
    float s = VmrpEngine::Instance().GetMotionSensitivity();
    // Y 轴取反：传感器 Y 正=上，MRP 屏幕 Y 正=下
    int xMg = static_cast<int>(data[0] * 102.0f * s);
    int yMg = -static_cast<int>(data[1] * 102.0f * s);
    int zMg = static_cast<int>(data[2] * 102.0f * s);
    VmrpEngine::Instance().SendMotion(xMg, yMg, zMg);
}
} // namespace

void VmrpEngine::StartSensor() {
    if (sensor_subscribed_) return;
    g_sensor_sub_id = OH_Sensor_CreateSubscriptionId();
    OH_SensorSubscriptionId_SetType(g_sensor_sub_id, SENSOR_TYPE_ACCELEROMETER);
    g_sensor_sub_attr = OH_Sensor_CreateSubscriptionAttribute();
    OH_SensorSubscriptionAttribute_SetSamplingInterval(g_sensor_sub_attr, 20000000); // 20ms
    g_sensor_subscriber = OH_Sensor_CreateSubscriber();
    OH_SensorSubscriber_SetCallback(g_sensor_subscriber, OnAccelerometerData);
    int r = OH_Sensor_Subscribe(g_sensor_sub_id, g_sensor_sub_attr, g_sensor_subscriber);
    if (r == SENSOR_SUCCESS) sensor_subscribed_ = true;
}

void VmrpEngine::StopSensor() {
    if (!sensor_subscribed_) return;
    OH_Sensor_Unsubscribe(g_sensor_sub_id, g_sensor_subscriber);
    OH_Sensor_DestroySubscriber(g_sensor_subscriber); g_sensor_subscriber = nullptr;
    OH_Sensor_DestroySubscriptionAttribute(g_sensor_sub_attr); g_sensor_sub_attr = nullptr;
    OH_Sensor_DestroySubscriptionId(g_sensor_sub_id); g_sensor_sub_id = nullptr;
    sensor_subscribed_ = false;
}
```

**关键参数**：
- `SENSOR_TYPE_ACCELEROMETER = 1`：加速度传感器类型
- `samplingInterval = 20000000`：20ms = 20000000ns，约 50Hz
- 转换系数 102：`1000 / 9.80665 ≈ 101.97`，取整为 102
- Y 轴取反：`yMg = -round(data.y * 102 * sensitivity)`

#### 3.5 灵敏度设置

```cpp
void VmrpEngine::SetMotionSensitivity(float s) {
    motion_sensitivity_ = s;
    if (api_.set_motion_sensitivity) api_.set_motion_sensitivity(s);
}
```

---

### 4. CMakeLists.txt — 链接 libohsensor.so

**文件**：`entry/src/main/cpp/CMakeLists.txt`

**变更**：

```cmake
target_link_libraries(vmrp_entry PUBLIC
    ...
    libohsensor.so    # OH_Sensor 加速度传感器 C 原生 API
)
```

---

### 5. vmrp_napi.cpp — N-API 绑定

**文件**：`entry/src/main/cpp/vmrp_napi.cpp`

**新增**：

```cpp
static napi_value SetMotionSensitivity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double val = 1.0;
    napi_get_value_double(env, args[0], &val);
    VmrpEngine::Instance().SetMotionSensitivity(static_cast<float>(val));
    return nullptr;
}

// 注册
{"setMotionSensitivity", nullptr, SetMotionSensitivity, nullptr, nullptr, nullptr, napi_default, nullptr},
```

---

### 6. Index.d.ts — TypeScript 类型声明

**文件**：`entry/src/main/cpp/types/libentry/Index.d.ts`

**新增**：

```typescript
export const sendMotion: (x: number, y: number, z: number) => number;
export const setMotionSensitivity: (sensitivity: number) => void;
```

---

### 7. VmrpEngine.ets — ETS 引擎封装

**文件**：`entry/src/main/ets/vmrp/VmrpEngine.ets`

**变更**：

```typescript
import { setMotionSensitivity as nativeSetMotionSensitivity, ... } from 'libentry.so';

export class VmrpEngineTs {
    setMotionSensitivity(sensitivity: number): void {
        nativeSetMotionSensitivity(sensitivity);
    }
}
```

---

### 8. Index.ets — 权限预请求 + 灵敏度传入

**文件**：`entry/src/main/ets/pages/Index.ets`

**核心变更**：

- **移除**：`sensor` 导入、`abilityAccessCtrl` 传感器检查逻辑、
  `requestAccelerometerPermission()`、`startAccelerometer()`/`stopAccelerometer()`
- **新增**：bootstrap 时预请求 ACCELEROMETER 权限（C 层 OH_Sensor 需要授权）
- **新增**：从 preferences 读取灵敏度，通过 `engine.setMotionSensitivity()` 传入 C 层

```typescript
// 预请求加速度传感器权限
const atManager = abilityAccessCtrl.createAtManager();
await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.ACCELEROMETER']);

// 读取灵敏度设置
const sensitivity = (await pref.get('motion_sensitivity', 1.0)) as number;
this.engine.setMotionSensitivity(sensitivity);
```

传感器订阅/取消完全由 C 层的上电/断电回调驱动，ETS 层不再参与。

---

### 9. Settings.ets — 灵敏度设置 UI

**文件**：`entry/src/main/ets/pages/Settings.ets`

**新增**："动感"设置分组，包含灵敏度滑块：

- 范围：0.2x ~ 3.0x，步长 0.1，默认 1.0x
- 持久化到 `vmrp_settings` preferences，key `motion_sensitivity`
- 需重启游戏后生效

---

## 日志观察

真机运行时 hilog 中的关键日志：

| 日志 | 标签 | 含义 |
|------|------|------|
| `OH_Sensor_Subscribe OK (accelerometer)` | `vmrp_engine` | 传感器订阅成功（上电） |
| `OH_Sensor_Unsubscribe OK (accelerometer)` | `vmrp_engine` | 传感器取消订阅（断电） |
| `motion power callback registered` | `vmrp_engine` | 上电/断电回调注册成功 |

---

## 兼容性说明

### SkyEngine 动感芯片 API 对照

| mr_plat code | SkyEngine 含义 | vmrp-ohos 实现 |
|--------------|----------------|----------------|
| 4001 | 停止监听 | `motion_enabled=0` |
| 4002 | 上电 | `motion_powered=1` + `vmrp_api_motion_power(1)` → 宿主开启传感器 |
| 4003 | 断电 | `motion_powered=0; motion_enabled=0` + `vmrp_api_motion_power(0)` → 宿主停止传感器 |
| 4004 | 晃动模式 | `motion_enabled=1; mode=SHAKE(0)` |
| 4005 | 倾斜模式 | `motion_enabled=1; mode=TILT(1)` |
| 4006 | 获取范围 | 返回 3000（±2000mG = ±2g） |

### T_MOTION_ACC 结构体布局

```c
// ARM 代码通过 mr_event param2 指向的地址读取
struct T_MOTION_ACC {
    int32 x;  // 偏移 0: X 轴加速度 (mG)
    int32 y;  // 偏移 4: Y 轴加速度 (mG)，已取反适配屏幕坐标系
    int32 z;  // 偏移 8: Z 轴加速度 (mG)
};  // 总大小: 12 字节
```

### 静止参考值

| 设备姿态 | x (mG) | y (mG) | z (mG) |
|----------|--------|--------|--------|
| 平放屏幕朝上 | ≈0 | ≈0 | ≈1000 |
| 竖持 | ≈0 | ≈1000 | ≈0 |
| 横持左倾 | ≈-1000 | ≈0 | ≈0 |

注：竖持时传感器 Y ≈ +9.8 m/s²（朝上），取反后 yMg ≈ +1000（屏幕 Y 正方向朝下），
与 MRP 游戏预期一致：设备顶部抬高时球往屏幕下方滚。

---

## 已知限制

1. **SHAKE vs TILT 语义未区分**：当前两种模式都传递相同的 T_MOTION_ACC 数据，
   不做晃动/倾斜的阈值判断。MRP 应用通常自行根据 mode 和数据做业务判断。

2. **权限需预授权**：C 层 `OH_Sensor_Subscribe` 在权限未授予时返回
   `SENSOR_PERMISSION_DENIED`。当前在 bootstrap 时预请求权限，
   如果用户拒绝，传感器将无法工作，但不会崩溃。

3. **灵敏度需重启游戏生效**：灵敏度倍率在 C 层作为全局变量生效，
   修改设置页后需重新启动 MRP 游戏才能应用新值。

---

## 修改文件汇总

### vmrp C 核心（直接编辑，不在 :restore_patched 列表）

| 文件 | 变更类型 |
|------|----------|
| `vmrp/src/mythroad/dsm.c` | motion 状态/缓存/投递/mr_plat 4001-4006 + vmrp_api_motion_power 调用 |
| `vmrp/src/mythroad/include/dsm.h` | 新增 4 个函数声明 |
| `vmrp/src/mythroad/include/mrporting.h` | 新增 MR_MOTION_EVENT_SHAKE/TILT 枚举 |
| `vmrp/src/vmrp_api.c` | API_CMD_MOTION + vmrp_api_motion_event() + motion_power 回调 + sensitivity |
| `vmrp/src/include/vmrp_api.h` | 新增 vmrp_api_motion_event/set_motion_power_cb/motion_power/set_motion_sensitivity 声明 |
| `vmrp/src/include/arm_ext_executor.h` | 新增 arm_ext_write_motion_acc 声明 |
| `vmrp/src/include/arm_ext_internal.h` | 新增 motion_acc_addr 字段 |

### vmrp C 核心（CMake 补丁注入，构建后恢复）

| 文件 | 补丁内容 |
|------|----------|
| `vmrp/src/arm_ext_executor.c` | arm_alloc(m,12) + arm_ext_write_motion_acc() 实现 |
| `vmrp/src/mythroad/mythroad.c` | dsm_write_motion_acc_to_arm() 桥接函数 |

### scripts 构建脚本

| 文件 | 变更 |
|------|------|
| `scripts/CMakeLists.txt` | 新增 2 个补丁段（OHOS_MOTION_ACC + OHOS_MOTION_ACC_BRIDGE） |

### HarmonyOS 应用层

| 文件 | 变更 |
|------|------|
| `entry/src/main/module.json5` | 新增 ohos.permission.ACCELEROMETER 权限 |
| `entry/src/main/resources/base/element/string.json` | 新增权限说明文案 |
| `entry/src/main/cpp/CMakeLists.txt` | 新增 libohsensor.so 链接 |
| `entry/src/main/cpp/vmrp_engine.h` | 新增 motion_event/set_motion_power_cb/set_motion_sensitivity 指针 + StartSensor/StopSensor/SetMotionSensitivity/GetMotionSensitivity |
| `entry/src/main/cpp/vmrp_engine.cpp` | OH_Sensor 传感器管理 + OnAccelerometerData 回调 + 上电/断电回调注册 |
| `entry/src/main/cpp/vmrp_napi.cpp` | 新增 SetMotionSensitivity N-API 函数 |
| `entry/src/main/cpp/include/vmrp_api.h` | 新增 vmrp_api 声明 |
| `entry/src/main/cpp/types/libentry/Index.d.ts` | 新增 setMotionSensitivity 类型声明 |
| `entry/src/main/ets/vmrp/VmrpEngine.ets` | 新增 setMotionSensitivity 封装 |
| `entry/src/main/ets/pages/Index.ets` | 移除 ETS 传感器代码，新增权限预请求 + 灵敏度传入 |
| `entry/src/main/ets/pages/Settings.ets` | 新增"动感"分组：灵敏度滑块 (0.2x~3.0x) |
