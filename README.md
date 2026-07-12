# vmrp 鸿蒙移植版 (vmrp-ohos)

将 [vmrp](https://github.com/msojocs/vmrp) MRP 模拟器移植到 HarmonyOS（鸿蒙）系统的端到端工程。

MRP（Mythroad）是斯凯平台的手机应用格式，其 `.mrp` 包内是 **ARM32 机器码**。本工程借助 Unicorn 引擎的 **arm-softmmu TCG 软件模拟**，在鸿蒙 ARM64 设备上运行 ARM32 代码——**无需宿主机支持 ARM32**，符合鸿蒙不支持 ARM32 的约束。

> **TL;DR** — 在 DevEco Studio 打开本工程 → 预构建 libvmrp.so → 编译运行即可在鸿蒙模拟器/真机上玩 MRP 游戏。

---

## 目录

- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [构建步骤详解](#构建步骤详解)
- [工程结构](#工程结构)
- [架构与关键技术](#架构与关键技术)
- [移植补丁说明](#移植补丁说明)
- [常见问题](#常见问题)

---

## 环境要求

以下软件**不入库**，需在其他电脑上自行安装：

| 软件 | 版本要求 | 用途 |
|------|---------|------|
| **DevEco Studio** | 含 HarmonyOS SDK API 26（HarmonyOS 6.0+） | 鸿蒙应用开发、编译、模拟器、签名 |
| **Git for Windows** | 任意版本 | 提供构建 Unicorn 所需的 POSIX sh/sed/rm |
| **Git** | 任意版本 | 克隆仓库 |

> DevEco Studio 自带 HarmonyOS SDK、NDK（ohos.toolchain.cmake）、node、ohpm 工具链，无需单独安装。

### 验证环境

```bash
# Git（需含 sh.exe，Git for Windows 的 usr/bin 下有）
git --version

# DevEco Studio 的 OHOS NDK 路径（构建脚本会自动探测）
# 默认: C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native
```

---

## 快速开始

```bash
# 1. 克隆（vmrp 源码已纳入仓库，无需 --recurse-submodules）
git clone https://github.com/Jiagu1218/vmrp-ohos.git
cd vmrp-ohos

# 2. 预构建 libvmrp.so（需 Git for Windows 提供 POSIX sh）
#    直接传 ABI 即可，vmrp 源码默认用项目内的 vmrp/ 目录
scripts\build_libvmpp_ohos.bat x86_64       # 模拟器
scripts\build_libvmpp_ohos.bat arm64-v8a    # 真机

# 3. 用 DevEco Studio 打开工程，或用 devecocli：
devecocli build
devecocli emulator start "Mate 70 RS"
devecocli run --device "Mate 70 RS"
```

启动后点「启动默认」运行内置的 dsm_gm（mythroad 主菜单），或点「选择 MRP」加载你自己的 `.mrp` 游戏文件。

---

## 构建步骤详解

### 第一步：预构建 libvmrp.so

鸿蒙 native 模块（libentry.so）依赖预构建的 `libvmrp.so`——它是 vmrp 核心 + Unicorn arm-softmmu 交叉编译的产物。

```bat
scripts\build_libvmpp_ohos.bat [abi]
```

- `abi`：`arm64-v8a`（真机，默认）或 `x86_64`（模拟器）

> 也支持显式指定源码目录的旧用法 `bat [vmrp_src] [abi]`，但通常不需要——脚本默认用项目内的 `vmrp/` 目录，它是本仓库版本管理的一部分。

产物输出到：
- `entry\src\main\cpp\prebuilt\<abi>\libvmrp.so`（CMake 链接用）
- `entry\libs\<abi>\libvmrp.so`（HAP 打包用）

**同时构建两个 ABI**（真机 + 模拟器都支持）：
```bat
scripts\build_libvmpp_ohos.bat arm64-v8a
scripts\build_libvmpp_ohos.bat x86_64
```

> 脚本内部用 OHOS NDK 的 `ohos.toolchain.cmake` + Ninja 交叉编译，复用 vmrp 的 `vmrp-shared` target（排除 main.c/e2e_control.c，不定义 VMRP_SDL_AUDIO，无 SDL 依赖）。
> **注意**：vmrp 源码（`vmrp/`）已纳入本仓库版本管理，不再是独立 git submodule。构建脚本默认编译此目录；如需更新上游，在 `vmrp/` 内 `git pull` 后同步提交到本仓库。

### 第二步：构建鸿蒙工程

```bash
devecocli build
```

或在 DevEco Studio 中直接「Build → Build Hap(s)」。构建会：
1. 用 CMake 编译 `entry/src/main/cpp/` 为 `libentry.so`（NAPI 桥接层），链接预构建的 `libvmrp.so` + 鸿蒙系统库（EGL/GLES/OHAudio/hilog）
2. 用 ArkTS 编译 UI 层
3. 打包成 HAP

### 第三步：运行

```bash
devecocli emulator start "Mate 70 RS"   # 启动模拟器
devecocli run --device "Mate 70 RS"      # 安装运行
```

真机（arm64）连接 USB 后同样用 `devecocli run --device <serial>`。

---

## 工程结构

```
vmrp-ohos/
├── vmrp/                          # vmrp 模拟器源码（已纳入版本管理）
│   └── third_party/unicorn/      #   Unicorn 引擎
├── ohos_src/                      # 鸿蒙专属源码（独立于 vmrp 树，避免上游冲突）
│   ├── ohos_image_decode.h        #   SkyEngine 图片/GIF API 声明
│   └── ohos_image_decode.cpp      #   鸿蒙原生 Image C API 实现
├── docs/                          # 补丁/功能文档
│   ├── skyengine-image-api.md     #   SkyEngine 图片接口文档
│   ├── motion-chip-adaptation.md  #   重力感应适配文档
│   ├── arm-alloc-oob-crash-fix.md #   arm_alloc 越界修复文档
│   ├── exception-heap-recovery.md #   UC_ERR_EXCEPTION 堆恢复文档
│   ├── platex-memory-extension.md #   PlatEx 内存扩展文档
│   └── timer-interval-override-fix.md  # Timer 间隔覆盖修复文档
├── scripts/                       # 预构建脚本
│   ├── build_libvmpp_ohos.bat    #   libvmrp.so 交叉编译入口
│   └── CMakeLists.txt             #   CMake wrapper（含移植补丁）
├── entry/                         # 鸿蒙 entry 模块
│   ├── src/main/cpp/              # Native 桥接层（C++）
│   │   ├── vmrp_napi.cpp          #   NAPI 入口（XComponent + 事件）
│   │   ├── vmrp_engine.cpp/.h     #   dlopen libvmrp.so + 引擎锁
│   │   ├── vmrp_renderer.cpp/.h   #   XComponent + EGL/GLES 渲染
│   │   ├── vmrp_audio.cpp/.h      #   OHAudio 拉流
│   │   ├── include/vmrp_api.h     #   vmrp C ABI（含鸿蒙扩展）
│   │   ├── types/libentry/Index.d.ts  # NAPI 类型声明
│   │   └── CMakeLists.txt         #   native 构建
│   ├── src/main/ets/              # ArkTS UI 层
│   │   ├── pages/Index.ets        #   主界面（XComponent + 虚拟键盘）
│   │   ├── pages/Settings.ets     #   设置页（内存/重力/震动）
│   │   ├── vmrp/VmrpEngine.ets    #   native 模块封装
│   │   └── vmrp/VmrpAssets.ets    #   mythroad 运行时资源管理
│   ├── src/main/resources/rawfile/mythroad/  # 内置运行时（dsm_gm.mrp + 字体，递归导入）
│   ├── libs/<abi>/                # libvmrp.so 打包位置（构建生成）
│   ├── build-profile.json5        # externalNativeBuild + abiFilters
│   └── oh-package.json5           # NAPI 类型声明引用
├── build-profile.json5            # 工程级构建配置
├── oh-package.json5               # 工程依赖
└── README.md                      # 本文件
```

---

## 架构与关键技术

### 整体架构

```
HarmonyOS App (API 26)
├── ArkTS UI（XComponent 屏幕 + 虚拟键盘 + 文件选择器 + 设置页）
├── Native 桥接（libentry.so）
│   ├── NAPI：init/start/stop/sendKey/submitEdit
│   ├── EGL/GLES：RGB565→RGBA 纹理渲染（XComponent 帧回调线程）
│   ├── OHAudio：pull 模型 PCM 拉流（音频回调线程）
│   └── 定时器驱动：timer loop 按间隔调度 vmrp_api_timer
│       ↓ vmrp_api.h（26+ 个 C 函数，无 SDL）
└── libvmrp.so（预构建）
    ├── vmrp 核心 + mythroad DSM 层
    ├── arm_ext_executor：Unicorn 执行 ARM ext
    ├── ohos_image_decode：鸿蒙原生图片/GIF 解码（Image C API）
    ├── ohos_gif_tick：GIF 动画帧推进（mr_timer 内驱动）
    └── unicorn arm-softmmu：TCG 软件模拟 ARM32
```

### 关键技术点

1. **arm-softmmu 是纯软件 TCG 模拟**：把 ARM32 指令翻译成宿主机指令执行，不依赖宿主 ARM32 硬件。因此在 ARM64/x86_64 鸿蒙上都能跑 MRP 的 ARM32 代码。

2. **vmrp 已有 SDL-free 共享库 API**（`vmrp_api.h`，26+ 个导出函数）：构建 `vmrp-shared` target 即可，不含 main.c，不定义 `VMRP_SDL_AUDIO`。这是移植的核心入口。

3. **渲染线程模型**：EGL surface 必须在 XComponent 帧回调线程（创建 surface 的同线程）渲染，否则 `eglSwapBuffers` 报 `EGL_BAD_SURFACE`。用 `OH_NativeXComponent_RegisterOnFrameCallback` 注册帧回调，在该线程做 `eglSwapBuffers`。

4. **像素对齐**：MRP 屏幕 240×320 → XComponent surface（如 840×1120）。`glViewport` 用 `eglQuerySurface` 获取的 surface 实际尺寸铺满；纹理过滤用 `GL_NEAREST` 保持像素艺术清晰。

5. **引擎单线程约束**：Unicorn ARM 引擎不支持并发。触摸线程的 `SendEvent` 和 timer 线程的 `StepTimer` 都会调 `uc_emu_start`。用 `std::mutex engine_mtx_` 串行化所有驱动 Unicorn 的调用，否则 TCG 的 TB cache 损坏导致 `translate-all.c g_assert_not_reached`（UC_ERR_EXCEPTION）闪退。

6. **音频 pull 模型**：`vmrp_api_audio_render_s16le(buf, frames)` 由宿主拉取 PCM，与 OHAudio 的 WriteData 回调天然匹配。44100Hz/2ch/S16LE。

7. **stdio→hilog 重定向**：vmrp 核心全用 `printf`/`fprintf`，鸿蒙下默认不进 hilog。在 `VmrpEngine::Load` 把 stdout/stderr 重定向到 pipe，读线程转发到 hilog，使崩溃信息、mr_open 等日志可见。

8. **SkyEngine 图片/GIF 解码**：使用鸿蒙原生 `OH_ImageSourceNative`/`OH_PixelmapNative` C API 解码图片（PNG/JPG→RGB565）和 GIF 多帧动画。GIF 动画由 `ohos_gif_tick()` 在 `mr_timer()` 内驱动，保证帧推进与 vmrp worker 线程串行，避免并发写 `mr_screenBuf`。详见 [docs/skyengine-image-api.md](docs/skyengine-image-api.md)。

9. **重力感应适配**：使用鸿蒙 `OH_Sensor` C API（加速度计），通过异步队列分发到 vmrp 事件系统，灵敏度/反转可在设置页调节。详见 [docs/motion-chip-adaptation.md](docs/motion-chip-adaptation.md)。

### 数据流

```
触摸事件 ──→ XComponent 触摸回调 ──→ SendEvent (加锁) ──→ vmrp_api_event ──→ ARM 事件处理
                                                                                       ↓
重力感应 ──→ OH_Sensor 回调 ──→ 异步队列 ──→ vmrp_api_event ──→ ARM 重力处理
                                                                                       ↓
定时器线程 ──→ StepTimer (加锁) ──→ vmrp_api_timer ──→ ARM 定时器逻辑 ──→ 绘图到 screen_buf
                                                                                       ↓                                     ↓
                                                          ohos_gif_tick() ──→ GIF 帧推进 ──→ RGB565 写入 screen_buf
                                                                                       ↓
XComponent 帧回调 ──→ ScreenBuffer (RGB565) ──→ EGL/GLES 渲染 ──→ eglSwapBuffers ──→ 屏幕
                                                                                       ↓
OHAudio 回调线程 ──→ PullAudio (不加锁) ──→ vmrp_api_audio_render_s16le ──→ PCM ──→ 扬声器

图片/GIF 解码路径：
MRP 调 mr_plat(300x) ──→ dsm.c ──→ ohos_image_decode ──→ OH_ImageSourceNative ──→ RGB565 ──→ mr_screenBuf
```

---

## 移植补丁说明

构建脚本 `scripts/CMakeLists.txt` 在 `add_subdirectory(vmrp)` 前会自动应用以下补丁（幂等，可重复运行）：

### 基础移植补丁

| 补丁 | 文件 | 原因 |
|------|------|------|
| **Unicorn /dev/null 探测** | unicorn/CMakeLists.txt | Windows 宿主下 `/dev/null` 不存在，Unicorn 主机架构探测失败。改为空字符串输入 |
| **Unicorn --cc wrapper** | unicorn/CMakeLists.txt | OHOS clang 是交叉编译器，裸调用不带 `--target` 导致 `qemu/configure` 误判宿主为 mingw32。用 sh wrapper 注入 `--target`/`--sysroot`；同时用 `string(REGEX REPLACE)` 匹配任意已有 wrapper 路径，支持跨 ABI（arm64-v8a ↔ x86_64）交替构建 |
| **Unicorn TCG 架构检测** | unicorn/CMakeLists.txt | Unicorn 的 CMakeLists.txt 用 `execute_process(COMMAND ${CMAKE_C_COMPILER} -dM -E -)` 检测宿主架构（选择 TCG 后端）。Windows 下 OHOS clang 默认 x86_64，所以 `__x86_64__` 被定义 → `UNICORN_TARGET_ARCH=i386` → 错误地编译 `tcg/i386` 后端。用 `.bat` wrapper（`ohos-cc.bat`，注入 `--target`/`--sysroot`）替代裸 clang，使目标架构正确定义 |
| **跨 ABI 补丁鲁棒性** | `build_libvmpp_ohos.bat` + `scripts/CMakeLists.txt` | 每次构建前 `git checkout --` 恢复 Unicorn CMakeLists.txt 到原始状态，防止上次 ABI 的 patch 残留导致下次替换不匹配 |
| **MAP_32BIT** | native_dsm_funcs.c | `MAP_32BIT` 是 x86-glibc 专有，OHOS musl 缺失，x86_64 模拟器构建失败。替换为 0（有 calloc 兜底） |
| **case 800 ARM 地址修复** | mythroad.c + arm_ext_executor.c | 部分 MRP（如 3D暴力摩托）的 cfunction loader 把 ext 放在 ARM 内存并用 ARM 地址调 case 800。arm_ext_load 把 ARM 地址当 host 指针读取导致全 0 崩溃。检测到 ARM 地址时用 `arm_ext_host_ptr` 转成 host 指针 |

### 稳定性修复补丁

| 补丁 | 文件 | 原因 |
|------|------|------|
| **ARM_ALLOC_U64** | arm_ext_executor.c | `arm_alloc` 分配大小用 `int` 计算，大内存请求时整数溢出导致分配过小，后续 `memset` 越界 SIGSEGV。改用 `uint64_t` 计算 + 边界守卫 |
| **MEMSET_BOUNDS_GUARD** | arm_ext_executor.c | `memset` 写入长度可能超过 `arm_alloc` 实际分配大小，导致堆溢出。增加边界检查 |
| **MEMSET_NULL_GUARD** | arm_ext_executor.c | case 14 中 `memset2` 目标指针可能为 NULL（未映射 ARM 地址），导致空指针解引用 SIGSEGV。增加 NULL 检查 |
| **UNMAPPED_GRACEFUL_EXIT** | arm_ext_executor.c | Unicorn 访问未映射 ARM 地址时 UC_ERR_EXCEPTION 直接崩溃。改为优雅退出当前 ARM 调用，返回 MR_IGNORE，避免闪退 |
| **EXCEPTION_HEAP_RECOVERY** | arm_ext_executor.c | 定时器线程中 UC_ERR_EXCEPTION 会导致 ARM 引擎状态损坏，后续所有调用均失败。检测到异常后重建 Unicorn 引擎 + 重映射内存，恢复正常运行 |
| **TIMER_NO_OVERRIDE** | mythroad.c | `arm_ext_call_dispatch(native_ext, 0, 50)` 硬编码 timer 间隔为 50ms，覆盖 MRP 应用自己设置的间隔，导致定时器运行过快。改为尊重应用设定的间隔 |

### 功能扩展补丁

| 补丁 | 文件 | 原因 |
|------|------|------|
| **PLATEX_MEM_EXT** | arm_ext_executor.c | SkyEngine `mr_platEx` 1001/1002/1012/1013 接口：获取/设置内存布局信息（IRAM/EXRAM/屏幕缓冲区地址和大小），MRP 应用通过此接口动态配置内存 |
| **GIF_TICK** | mythroad.c | GIF 动画驱动：在 `mr_timer()` 末尾注入 `ohos_gif_tick()` 调用，每 tick 推进活跃 GIF 动画的当前帧，实现动画播放 |

### 鸿蒙专属源码（ohos_src/）

不在 vmrp 源码树内，由 CMake 单独编译链接，避免上游合并冲突：

| 文件 | 功能 |
|------|------|
| `ohos_image_decode.cpp` | SkyEngine 图片/GIF API 的鸿蒙原生实现。使用 `OH_ImageSourceNative`/`OH_PixelmapNative`（鸿蒙 Image C API），支持 PNG/JPG 解码为 RGB565、GIF 多帧解码与动画播放、DMA 刷屏、直接绘制 |

**已实现的 SkyEngine 接口**（详见 [docs/skyengine-image-api.md](docs/skyengine-image-api.md)）：

| 接口号 | 功能 | 状态 |
|--------|------|------|
| 3001 | 获取图片信息（宽高） | ✅ |
| 3002 | 图片解码→RGB565 | ✅ |
| 3004 | GIF 多帧解码 | ✅ |
| 3005 | 释放 GIF 资源 | ✅ |
| 3007 | MR_DRAW_BUFFER | ✅ (no-op) |
| 3008 | MR_GET_ACT_LAYER | ✅ (MR_IGNORE) |
| 3009 | DMA 刷屏 | ✅ |
| 3010 | 直接绘制图片 | ✅ |
| 3011 | 显示 GIF 动画 | ✅ |
| 3012 | 停止 GIF 动画 | ✅ |
| 3014/3015 | MTK 私有资源格式 | 待定（低优先级） |

> 这些补丁在构建时临时应用到 vmrp 源码的工作区文件，每次构建前由 `:restore_patched` 恢复到提交状态，不残留。需持久保留的改动应直接提交到本仓库的 `vmrp/` 目录。

---

## 常见问题

### Q: 构建报 `Unicorn's qemu/configure needs a POSIX sh`
A: 安装 Git for Windows，确保 `sh.exe` 在 PATH。脚本会自动探测 `C:\Program Files\Git\usr\bin`。

### Q: 构建报 `clang.exe either does not exist or does not work`
A: OHOS NDK 路径含空格（`Program Files`）。脚本会自动创建无空格 junction `C:\ohos_ndk`。若失败，手动执行：
```bat
mklink /J C:\ohos_ndk "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native"
set OHOS_SDK_NATIVE=C:\ohos_ndk
```

### Q: 运行报 `Abi type supported by the device does not match`
A: 模拟器是 x86_64，真机是 arm64。需构建对应 ABI 的 libvmrp.so：
```bat
scripts\build_libvmpp_ohos.bat x86_64   # 模拟器
```

### Q: 游戏启动后文字不显示
A: 检查工作目录设置。vmrp 的 `dsmWorkPath` 默认 `"mythroad/"`，chdir 目标必须是 mythroad 的**父目录**（即 files/），而非 mythroad 本身，否则字体路径 `mythroad/system/gb16.uc2` 会多嵌套一层。

### Q: 部分游戏启动失败返回列表
A: 这是 vmrp 对个别游戏的兼容性限制（如 3D暴力摩托）。vmrp 对每个游戏逐个逆向适配，未被适配的游戏（无 app_compat profile）可能无法运行。已适配的 dsm_gm、罪恶都市（gghjt）等可正常运行。

### Q: 游戏运行中触摸闪退
A: 已通过引擎锁（`engine_mtx_`）修复。若仍出现，确认 `vmrp_engine.cpp` 的 SendEvent/StepTimer 等方法都持有 `engine_mtx_` 锁。

### Q: 游戏画面花屏/卡死
A: 已通过 `UNMAPPED_GRACEFUL_EXIT` 补丁修复——当 ARM 代码访问未映射地址时优雅退出而非崩溃。若仍出现，可能是 MRP 应用的绘图指令超出了屏幕缓冲区范围。

### Q: 游戏运行一段时间后定时器停了
A: 已通过 `EXCEPTION_HEAP_RECOVERY` 补丁修复——UC_ERR_EXCEPTION 后自动重建 Unicorn 引擎。若仍出现，查看 hilog 中 `vmrp_core:` 标签的日志。

### Q: 游戏中图片不显示
A: SkyEngine 图片 API（3001-3012）已实现。若图片仍不显示，可能是 MRP 使用了 3014/3015（MTK 私有资源格式，暂未实现），或图片文件路径无法通过 `mr_open` 访问。

### Q: 重力感应不工作
A: 动感芯片已适配（事件类型 MR_MOTION_EVENT=18）。需设备支持加速度计且授权 `ohos.permission.ACCELEROMETER`（已声明）。设置页可调灵敏度（0.2x-3.0x）和 Y 轴反转。若游戏从未调 `mr_plat(4002)` 上电，传感器未启动则无数据。

### Q: vmrp/ 目录下显示有未提交的修改
A: 这是正常的。CMake 补丁在构建时修改 vmrp 源码，部分文件不在 `:restore_patched` 恢复列表中。这些修改不影响远程仓库（已提交的文件内容是正确的），其他设备 clone 后构建时会自动应用补丁。

---

## 许可

vmrp 源码遵循其原始许可（见 [vmrp](https://github.com/msojocs/vmrp) 上游）。本移植工程的鸿蒙适配代码可自由使用。

## 致谢

- [vmrp](https://github.com/msojocs/vmrp) — MRP 模拟器核心
- [Unicorn Engine](https://www.unicorn-engine.org/) — 多架构 CPU 模拟框架
