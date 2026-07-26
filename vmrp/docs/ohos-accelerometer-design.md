# vmrp-ohos 重力感应适配方案

本文档记录在 vmrp-ohos（HarmonyOS）上适配 MRP 重力感应功能的完整设计方案，供后续实现参考。

> 状态：**待实现**（设计完成，代码尚未编写）

---

## 1. 背景

部分 MRP 游戏（如某些赛车、平衡球、体感类游戏）依赖手机重力感应（加速度传感器）进行交互。当前 vmrp-ohos 未实现任何传感器支持，这些游戏的重力感应功能不可用。

### MRP 重力感应协议（斯凯 SkyEngine 标准）

来源：[gddhy.net SkyEngine API 文档](https://gddhy.net/2022/skyengine-api/mr_plat(4005).htm)

**MRP 应用侧 API：**

| 调用 | 作用 |
|---|---|
| `mr_plat(4004, 0)` | 开启**晃动模式**监听 |
| `mr_plat(4005, 0)` | 开启**倾斜模式**监听 |
| `mr_plat(4001, 0)` | 停止监听 |

**平台侧事件投递：**

平台通过 MRP 的事件回调 `dealevent(int32 code, int32 param1, int32 param2)` 投递传感器数据：

```
dealevent(
  MR_MOTION_EVENT,        // code = 18
  <子类型>,                // param1: 0=SHAKE(晃动), 1=TILT(倾斜)
  <T_MOTION_ACC 指针>      // param2: 指向三轴加速度结构体的指针
)
```

**`T_MOTION_ACC` 数据结构：**

```c
struct T_MOTION_ACC {
    int32 x;   // X 轴加速度（毫g，1g=1000mG）
    int32 y;   // Y 轴加速度
    int32 z;   // Z 轴加速度（静止平放约 1000）
};
```

---

## 2. 现状分析

### 2.1 vmrp 引擎侧

| 检查项 | 结果 |
|---|---|
| `MR_MOTION_EVENT` 枚举 | ✅ 已定义（`mrporting.h:102`，值=18），但**从未被使用/产生/分发** |
| `mr_event(type, param1, param2)` | ✅ 已实现（`mythroad.c:4161`），支持任意 type，会调用 MRP 应用的 `dealevent` |
| `vmrp_api_event(code, p0, p1)` | ✅ 已导出（`vmrp_api.c:644`），链路：`vmrp_api_event` → `event()` → `vmrp_runtime_event` → `mr_event()` |
| `mr_plat(4001/4004/4005)` 处理 | ❌ 未实现（`dsm.c:1291` 的 `mr_plat` 无这些 case，走 default 返回 `MR_IGNORE`） |
| `T_MOTION_ACC` 结构定义 | ❌ 项目中无此定义 |
| 传感器数据缓冲区 | ❌ 不存在 |

**结论：** 引擎的事件分发基础设施完整，`vmrp_api_event(18, ...)` 即可触发 `dealevent`。缺少的是：(1) `mr_plat` 的传感器开关处理；(2) 一块存储 `T_MOTION_ACC` 的缓冲区及其写入入口。

### 2.2 鸿蒙宿主侧

| 检查项 | 结果 |
|---|---|
| `@ohos.sensor` / `@kit.SensorServiceKit` 使用 | ❌ 无任何传感器代码 |
| 传感器数据 → native 的传递通道 | ❌ 无（现有 `sendKey` 只传 2 参数，无传感器方法） |
| `ohos.permission.ACCELEROMETER` 权限 | ❌ 未声明（仅有 `INTERNET`） |

### 2.3 现有事件传递链路（参照）

```
[ETS Index.ets]  onKeyTouch → engine.sendKey(type, key)
       ↓
[VmrpEngine.ets]  sendKey → nativeSendKey (import from libentry.so)
       ↓
[vmrp_napi.cpp]   SendKey() → VmrpEngine::SendEvent(type, key, 0)
       ↓                      (持 engine_mtx_ 锁)
[vmrp_engine.cpp] SendEvent() → api_.event(code, p0, p1)
       ↓
[libvmrp.so]      vmrp_api_event() → event() → mr_event() → dealevent()
```

新增传感器通道需复用此链路，但 param2（指针）的处理需特殊设计。

---

## 3. 设计方案

### 3.1 整体架构

```
┌─────────────────────────────────────────────────┐
│ HarmonyOS ETS (Index.ets)                       │
│  sensor.on(ACCELEROMETER) → engine.sendMotion() │
└──────────────────────┬──────────────────────────┘
                       ↓ (napi)
┌─────────────────────────────────────────────────┐
│ vmrp_napi.cpp / vmrp_engine.cpp                 │
│  SendMotion(x,y,z) → api_.motion_event(x,y,z)   │
└──────────────────────┬──────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────┐
│ libvmrp.so (新增导出符号)                        │
│  vmrp_api_motion_event(x,y,z)                   │
│    → dsm_set_motion_acc(x,y,z)                  │
│      → 写入静态 T_MOTION_ACC 缓冲区              │
│      → mr_event(MR_MOTION_EVENT, mode, &acc)    │
└─────────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────┐
│ vmrp 引擎内部                                    │
│  mr_plat(4004/4005) → motion_enabled=1 (新增)    │
│  mr_event(18,...) → dealevent(18, mode, ptr)    │
└─────────────────────────────────────────────────┘
```

### 3.2 关键设计决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 新增引擎 API vs 复用 `vmrp_api_event` | **新增 `vmrp_api_motion_event`** | param2 是指针，需引擎内部管理静态结构体地址；鸿蒙侧无法直接构造有效的 MRP 可读指针 |
| 缓冲区：动态分配 vs 静态全局 | **静态全局 `motion_acc`** | 地址固定、无需分配/释放、引擎锁串行化保证线程安全 |
| 采样频率 | `'game'`（~20Hz） | 平衡流畅度与 CPU 开销；回调里判断 `running` 状态跳过无游戏时的调用 |
| 是否触发重绘 | **不调 `RequestRender()`** | 传感器高频（20Hz），MRP 自身 timer 会驱动重绘；避免无谓渲染风暴 |
| 数据单位 | **mG（毫g）** | MRP 协议标准单位；HarmonyOS 传感器返回 m/s²，转换系数 ×102 |
| `mr_plat` 返回值 | `MR_SUCCESS` | 让 MRP 应用认为监听已成功开启/关闭 |

---

## 4. 实现步骤

### 第 1 步：vmrp 引擎侧（C 源码）

#### 4.1.1 `vmrp/src/mythroad/dsm.c`

**(a) 文件顶部全局区新增：**

```c
/*
 * MRP 重力感应支持（mr_plat 4001/4004/4005 + MR_MOTION_EVENT）。
 * 参考：gddhy.net SkyEngine API - mr_plat(4004/4005)。
 *
 * T_MOTION_ACC：三轴加速度，单位 mG（毫g，1g=1000）。
 * 作为静态全局缓冲区，其地址作为 mr_event 的 param2 指针传给
 * MRP 应用的 dealevent 回调。地址固定，引擎锁串行化保证安全。
 */
static int motion_enabled = 0;  /* mr_plat(4004/4005)=1, 4001=0 */
static int motion_mode = 0;     /* 0=MR_MOTION_EVENT_SHAKE, 1=MR_MOTION_EVENT_TILT */
static struct { int32 x; int32 y; int32 z; } motion_acc = {0, 0, 1000};
```

**(b) `mr_plat()`（L1291）的 switch 新增 case：**

```c
case 4001:  // 停止动感芯片监听
    motion_enabled = 0;
    return MR_SUCCESS;
case 4004:  // 动感芯片监听晃动模式
    motion_enabled = 1;
    motion_mode = 0;  // MR_MOTION_EVENT_SHAKE
    return MR_SUCCESS;
case 4005:  // 动感芯片监听倾斜模式
    motion_enabled = 1;
    motion_mode = 1;  // MR_MOTION_EVENT_TILT
    return MR_SUCCESS;
```

**(c) 新增宿主调用入口函数：**

```c
/*
 * 宿主写入最新加速度数据并投递 MR_MOTION_EVENT。
 * 仅在 MRP 应用已调用 mr_plat(4004/4005) 开启监听时投递。
 * x/y/z 单位 mG（毫g），静止平放约 (0, 0, 1000)。
 * 调用方（vmrp_api_motion_event）保证已持有引擎锁。
 */
void dsm_set_motion_acc(int32 x, int32 y, int32 z) {
    motion_acc.x = x;
    motion_acc.y = y;
    motion_acc.z = z;
    if (motion_enabled) {
        mr_event(MR_MOTION_EVENT, motion_mode, (int32)(uintptr_t)&motion_acc);
    }
}
```

**(d) 在 `dsm.c` 或相邻头文件中暴露声明：**

```c
void dsm_set_motion_acc(int32 x, int32 y, int32 z);
```

> **注意**：`dsm.c` 不在构建脚本的 `:restore_patched` 列表中（该列表仅含 `mythroad.c`、`native_dsm_funcs.c`、`arm_ext_executor.c`、`network.c`、`unicorn/CMakeLists.txt`），修改安全持久。

#### 4.1.2 `vmrp/src/vmrp_api.h`

新增导出声明：

```c
/*
 * 重力感应：写入三轴加速度（mG）并投递 MR_MOTION_EVENT。
 * 仅当 MRP 应用已调用 mr_plat(4004/4005) 开启监听时才实际投递事件。
 * 静止平放参考值：x=0, y=0, z=1000。
 */
VMRP_EXPORT int vmrp_api_motion_event(int x_mg, int y_mg, int z_mg);
```

#### 4.1.3 `vmrp/src/vmrp_api.c`

新增实现（参照现有 `vmrp_api_event` 的同步路径）：

```c
VMRP_EXPORT int vmrp_api_motion_event(int x_mg, int y_mg, int z_mg) {
    if (!api_running || vmrp_is_exited()) {
        api_running = 0;
        pending_timer_ms = 0;
        return -1;
    }
    /* 同步路径：复用引擎锁（与 vmrp_api_event 相同的串行化保证） */
    dsm_set_motion_acc(x_mg, y_mg, z_mg);
    if (vmrp_is_exited()) {
        api_running = 0;
        pending_timer_ms = 0;
    }
    return 0;
}
```

> **注意**：`vmrp_api.c` 也不在 `:restore_patched` 列表中，修改安全。

#### 4.1.4 重新编译 libvmrp.so

用现有 `scripts\build_libvmpp_ohos.bat` 分别构建两个 ABI：

```bash
# arm64-v8a（真机）
scripts\build_libvmpp_ohos.bat ..\vmrp arm64-v8a

# x86_64（模拟器）
scripts\build_libvmpp_ohos.bat ..\vmrp x86_64
```

产物替换：
- `entry/src/main/cpp/prebuilt/<abi>/libvmrp.so`
- `entry/libs/<abi>/libvmrp.so`

---

### 第 2 步：鸿蒙 native 侧（C++）

#### 4.2.1 `entry/src/main/cpp/include/vmrp_api.h`

同步新增声明（与引擎侧一致）：

```c
VMRP_EXPORT int vmrp_api_motion_event(int x_mg, int y_mg, int z_mg);
```

#### 4.2.2 `entry/src/main/cpp/vmrp_engine.h`

**(a) `VmrpApi` 结构体新增函数指针字段（L30 附近）：**

```cpp
int (*motion_event)(int, int, int);
```

**(b) `VmrpEngine` 类新增方法声明（L71 附近）：**

```cpp
// 重力感应数据（mG 单位）
int SendMotion(int x, int y, int z);
```

#### 4.2.3 `entry/src/main/cpp/vmrp_engine.cpp`

**(a) `Load()` 中解析符号（L122 附近）：**

```cpp
RESOLVE_SYM(so_handle_, "vmrp_api_motion_event", motion_event, int (*)(int, int, int));
```

**(b) 方法实现（L175 附近，参照 `SendEvent`）：**

```cpp
int VmrpEngine::SendMotion(int x, int y, int z) {
    std::lock_guard<std::mutex> lk(engine_mtx_);
    return api_.motion_event(x, y, z);
}
```

> **关键并发约束**：复用 `engine_mtx_` 锁。`mr_event` 内部执行 ARM/Lua 代码，必须串行化。

#### 4.2.4 `entry/src/main/cpp/vmrp_napi.cpp`

**(a) 新增 NAPI 函数（参照 `SendKey` L285-297）：**

```cpp
// sendMotion(x, y, z): 发送重力感应数据（mG 单位）。
static napi_value SendMotion(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t x = 0, y = 0, z = 0;
    napi_get_value_int32(env, args[0], &x);
    napi_get_value_int32(env, args[1], &y);
    napi_get_value_int32(env, args[2], &z);
    VmrpEngine::Instance().SendMotion(x, y, z);
    // 注意：不调 RequestRender()，MRP 自身 timer 驱动重绘
    return nullptr;
}
```

**(b) 在模块注册数组 `desc[]`（L474-493）新增条目：**

```cpp
{ "sendMotion", nullptr, nullptr, nullptr, nullptr, SendMotion, napi_default, nullptr },
```

#### 4.2.5 `entry/src/main/cpp/types/libentry/Index.d.ts`

新增 TS 声明：

```ts
export const sendMotion: (x: number, y: number, z: number) => number;
```

---

### 第 3 步：鸿蒙 ETS 侧

#### 4.3.1 `entry/src/main/ets/vmrp/VmrpEngine.ets`

**(a) import 新增（L13-19 附近）：**

```ts
import { sendMotion as nativeSendMotion } from 'libentry.so';
```

**(b) `VmrpEngineTs` 类新增方法（L75 附近）：**

```ts
// 发送重力感应数据（mG 单位，静止平放 z≈1000）
sendMotion(xMg: number, yMg: number, zMg: number): number {
  return nativeSendMotion(xMg, yMg, zMg);
}
```

#### 4.3.2 `entry/src/main/ets/pages/Index.ets`

**(a) import 新增：**

```ts
import { sensor } from '@kit.SensorServiceKit';
```

**(b) 新增成员变量与方法：**

```ts
private sensorSubscribed = false;

// 开启加速度传感器订阅（游戏运行时调用）
startAccelerometer(): void {
  if (this.sensorSubscribed) return;
  try {
    sensor.on(sensor.SensorId.ACCELEROMETER, { interval: 'game' },
      (data: sensor.AccelerometerResponse) => {
        if (!this.running) return;
        // m/s² → mG：×1000/9.80665 ≈ ×102
        const xMg = Math.round(data.x * 102);
        const yMg = Math.round(data.y * 102);
        const zMg = Math.round(data.z * 102);
        this.engine.sendMotion(xMg, yMg, zMg);
      });
    this.sensorSubscribed = true;
  } catch (e) {
    console.error(`sensor.on failed: ${JSON.stringify(e)}`);
  }
}

stopAccelerometer(): void {
  if (!this.sensorSubscribed) return;
  try {
    sensor.off(sensor.SensorId.ACCELEROMETER);
  } catch (e) { /* 忽略 */ }
  this.sensorSubscribed = false;
}
```

**(c) 生命周期挂钩：**

- `bootstrap()` 成功启动游戏后调 `this.startAccelerometer()`
- `aboutToDisappear()` 调 `this.stopAccelerometer()`

#### 4.3.3 `entry/src/main/module.json5`

`requestPermissions` 数组新增：

```json5
{
  "name": "ohos.permission.ACCELEROMETER",
  "reason": "$string:permission_accelerometer_reason",
  "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" }
}
```

#### 4.3.4 `entry/src/main/resources/base/element/string.json`

新增权限说明字符串：

```json
{ "name": "permission_accelerometer_reason", "value": "运行支持重力感应的MRP程序需要读取加速度传感器" }
```

#### 4.3.5 运行时权限请求

`ACCELEROMETER` 是 `user_grant` 权限，需运行时弹窗申请。在 `EntryAbility` 的 `onWindowStageCreate` 或 `Index.ets` 的 `bootstrap` 中：

```ts
import { abilityAccessCtrl } from '@kit.AbilityKit';

const atManager = abilityAccessCtrl.createAtManager();
atManager.requestPermissionsFromUser(getContext(this), ['ohos.permission.ACCELEROMETER']);
```

---

## 5. 数据单位与坐标系

### 5.1 单位换算

| 来源 | 单位 | 目标 | 单位 | 换算 |
|---|---|---|---|---|
| HarmonyOS 传感器 | m/s² | MRP `T_MOTION_ACC` | mG（毫g） | `mG = m/s² × 1000 / 9.80665 ≈ m/s² × 102` |

### 5.2 坐标系

HarmonyOS 加速度传感器坐标系（手机竖屏）：
- `x`：右为正
- `y`：上为正
- `z`：屏幕正面朝外为正（平放桌面时 z≈+9.8 m/s²）

静止状态参考值：

| 手机姿态 | x (mG) | y (mG) | z (mG) |
|---|---|---|---|
| 平放桌面（屏幕朝上） | 0 | 0 | 1000 |
| 竖屏手持 | 0 | 1000 | 0 |
| 横屏（左旋） | 1000 | 0 | 0 |

> **注意**：MRP 原始设备坐标系可能与 HarmonyOS 不同（尤其屏幕旋转时），实现后需根据实际游戏表现微调轴映射。

---

## 6. 待确认 / 风险项

1. **坐标系映射**：HarmonyOS 与 MRP 设备坐标系轴定义可能不一致，可能需要根据屏幕方向调整。先用直接透传验证，再微调。

2. **native ext（Unicorn）模式下的指针有效性**：`&motion_acc` 是宿主进程地址。纯 DSM 模式下 Lua 的 `dealevent` 可正确读取（宿主地址有效）。若游戏走 native ext（ARM 代码读该指针），需将缓冲区映射到 ARM 地址空间。多数重力游戏为纯 Lua/DSM，先不处理 native ext 情况。

3. **采样频率与性能**：`'game'` 档约 20Hz，每次触发 `mr_event` 即执行一轮 ARM/Lua。高频事件可能与 timer/触摸竞争引擎锁。若出现卡顿，降至 `'ui'`（~16Hz）或加本地节流。

4. **缺少测试用例**：目前不确定哪些 MRP 游戏使用了重力感应。实现后可通过搜索 MRP 字节码中的 `mr_plat(4004/4005)` 调用或 `MR_MOTION_EVENT` 引用来寻找测试游戏。

---

## 7. 参考资源

- [gddhy.net SkyEngine API - mr_plat(4005) 倾斜模式](https://gddhy.net/2022/skyengine-api/mr_plat(4005).htm)
- [gddhy.net SkyEngine API - mr_plat(4004) 晃动模式](https://gddhy.net/2022/skyengine-api/mr_plat(4004).htm)
- [gddhy.net SkyEngine API - mr_plat(4001) 停止监听](https://gddhy.net/2022/skyengine-api/mr_plat(4001).htm)
- [HarmonyOS @ohos.sensor 传感器 API 参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-sensor)
- [HarmonyOS Sensor Service Kit 开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/sensorservice-kit-intro)
- [vmrp/mrpdev 斯凯 MRP 开发文档/SDK 备份](https://github.com/vmrp/mrpdev)
