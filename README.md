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
| **Git** | 任意版本 | 克隆仓库与子模块 |

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
# 1. 克隆（含子模块：vmrp 源码 + unicorn）
git clone --recurse-submodules https://github.com/<你的用户名>/vmrp-ohos.git
cd vmrp-ohos

# 若已克隆但忘了子模块：
git submodule update --init --recursive

# 2. 预构建 libvmrp.so（需 Git for Windows 提供 POSIX sh）
#    参数2=ABI（arm64-v8a 真机 / x86_64 模拟器），vmrp 源码默认是子模块目录
scripts\build_libvmpp_ohos.bat vmrp x86_64       # 模拟器
scripts\build_libvmpp_ohos.bat vmrp arm64-v8a     # 真机

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
scripts\build_libvmpp_ohos.bat [vmrp_src] [abi]
```

- `vmrp_src`：vmrp 源码目录（默认 `..\vmrp`）
- `abi`：`arm64-v8a`（真机，默认）或 `x86_64`（模拟器）

产物输出到：
- `entry\src\main\cpp\prebuilt\<abi>\libvmrp.so`（CMake 链接用）
- `entry\libs\<abi>\libvmrp.so`（HAP 打包用）

**同时构建两个 ABI**（真机 + 模拟器都支持）：
```bat
scripts\build_libvmpp_ohos.bat vmrp arm64-v8a
scripts\build_libvmpp_ohos.bat vmrp x86_64
```

> 脚本内部用 OHOS NDK 的 `ohos.toolchain.cmake` + Ninja 交叉编译，复用 vmrp 的 `vmrp-shared` target（排除 main.c/e2e_control.c，不定义 VMRP_SDL_AUDIO，无 SDL 依赖）。

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
├── vmrp/                          # [git submodule] vmrp 模拟器源码
│   └── third_party/unicorn/      #   [嵌套 submodule] Unicorn 引擎
├── scripts/                       # 预构建脚本
│   ├── build_libvmpp_ohos.bat    #   libvmrp.so 交叉编译入口
│   └── CMakeLists.txt             #   CMake wrapper（含移植补丁）
├── entry/                         # 鸿蒙 entry 模块
│   ├── src/main/cpp/              # Native 桥接层（C++）
│   │   ├── vmrp_napi.cpp          #   NAPI 入口（XComponent + 事件）
│   │   ├── vmrp_engine.cpp/.h     #   dlopen libvmrp.so + 引擎锁
│   │   ├── vmrp_renderer.cpp/.h   #   XComponent + EGL/GLES 渲染
│   │   ├── vmrp_audio.cpp/.h      #   OHAudio 拉流
│   │   ├── include/vmrp_api.h     #   vmrp C ABI（18 个导出函数）
│   │   ├── types/libentry/Index.d.ts  # NAPI 类型声明
│   │   └── CMakeLists.txt         #   native 构建
│   ├── src/main/ets/              # ArkTS UI 层
│   │   ├── pages/Index.ets        #   主界面（XComponent + 虚拟键盘）
│   │   ├── vmrp/VmrpEngine.ets    #   native 模块封装
│   │   └── vmrp/VmrpAssets.ets    #   mythroad 运行时资源管理
│   ├── src/main/resources/rawfile/mythroad/  # 内置运行时（dsm_gm.mrp + 字体）
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
├── ArkTS UI（XComponent 屏幕 + 虚拟键盘 + 文件选择器）
├── Native 桥接（libentry.so）
│   ├── NAPI：init/start/stop/sendKey/submitEdit
│   ├── EGL/GLES：RGB565→RGBA 纹理渲染（XComponent 帧回调线程）
│   ├── OHAudio：pull 模型 PCM 拉流（音频回调线程）
│   └── 定时器驱动：timer loop 按间隔调度 vmrp_api_timer
│       ↓ vmrp_api.h（18 个 C 函数，无 SDL）
└── libvmrp.so（预构建）
    ├── vmrp 核心 + mythroad DSM 层
    ├── arm_ext_executor：Unicorn 执行 ARM ext
    └── unicorn arm-softmmu：TCG 软件模拟 ARM32
```

### 关键技术点

1. **arm-softmmu 是纯软件 TCG 模拟**：把 ARM32 指令翻译成宿主机指令执行，不依赖宿主 ARM32 硬件。因此在 ARM64/x86_64 鸿蒙上都能跑 MRP 的 ARM32 代码。

2. **vmrp 已有 SDL-free 共享库 API**（`vmrp_api.h`，18 个导出函数）：构建 `vmrp-shared` target 即可，不含 main.c，不定义 `VMRP_SDL_AUDIO`。这是移植的核心入口。

3. **渲染线程模型**：EGL surface 必须在 XComponent 帧回调线程（创建 surface 的同线程）渲染，否则 `eglSwapBuffers` 报 `EGL_BAD_SURFACE`。用 `OH_NativeXComponent_RegisterOnFrameCallback` 注册帧回调，在该线程做 `eglSwapBuffers`。

4. **像素对齐**：MRP 屏幕 240×320 → XComponent surface（如 840×1120）。`glViewport` 用 `eglQuerySurface` 获取的 surface 实际尺寸铺满；纹理过滤用 `GL_NEAREST` 保持像素艺术清晰。

5. **引擎单线程约束**：Unicorn ARM 引擎不支持并发。触摸线程的 `SendEvent` 和 timer 线程的 `StepTimer` 都会调 `uc_emu_start`。用 `std::mutex engine_mtx_` 串行化所有驱动 Unicorn 的调用，否则 TCG 的 TB cache 损坏导致 `translate-all.c g_assert_not_reached`（UC_ERR_EXCEPTION）闪退。

6. **音频 pull 模型**：`vmrp_api_audio_render_s16le(buf, frames)` 由宿主拉取 PCM，与 OHAudio 的 WriteData 回调天然匹配。44100Hz/2ch/S16LE。

7. **stdio→hilog 重定向**：vmrp 核心全用 `printf`/`fprintf`，鸿蒙下默认不进 hilog。在 `VmrpEngine::Load` 把 stdout/stderr 重定向到 pipe，读线程转发到 hilog，使崩溃信息、mr_open 等日志可见。

### 数据流

```
触摸事件 ──→ XComponent 触摸回调 ──→ SendEvent (加锁) ──→ vmrp_api_event ──→ ARM 事件处理
                                                                                      ↓
定时器线程 ──→ StepTimer (加锁) ──→ vmrp_api_timer ──→ ARM 定时器逻辑 ──→ 绘图到 screen_buf
                                                                                      ↓
XComponent 帧回调 ──→ ScreenBuffer (RGB565) ──→ EGL/GLES 渲染 ──→ eglSwapBuffers ──→ 屏幕
                                                                                      ↓
OHAudio 回调线程 ──→ PullAudio (不加锁) ──→ vmrp_api_audio_render_s16le ──→ PCM ──→ 扬声器
```

---

## 移植补丁说明

构建脚本 `scripts/CMakeLists.txt` 在 `add_subdirectory(vmrp)` 前会自动应用以下补丁（幂等，可重复运行）：

| 补丁 | 文件 | 原因 |
|------|------|------|
| **Unicorn /dev/null 探测** | unicorn/CMakeLists.txt | Windows 宿主下 `/dev/null` 不存在，Unicorn 主机架构探测失败。改为空字符串输入 |
| **Unicorn --cc wrapper** | unicorn/CMakeLists.txt | OHOS clang 是交叉编译器，裸调用不带 `--target` 导致 `qemu/configure` 误判宿主为 mingw32。用 sh wrapper 注入 `--target`/`--sysroot`；同时用 `string(REGEX REPLACE)` 匹配任意已有 wrapper 路径，支持跨 ABI（arm64-v8a ↔ x86_64）交替构建 |
| **Unicorn TCG 架构检测** | unicorn/CMakeLists.txt | Unicorn 的 CMakeLists.txt 用 `execute_process(COMMAND ${CMAKE_C_COMPILER} -dM -E -)` 检测宿主架构（选择 TCG 后端）。Windows 下 OHOS clang 默认 x86_64，所以 `__x86_64__` 被定义 → `UNICORN_TARGET_ARCH=i386` → 错误地编译 `tcg/i386` 后端。用 `.bat` wrapper（`ohos-cc.bat`，注入 `--target`/`--sysroot`）替代裸 clang，使目标架构正确定义 |
| **跨 ABI 补丁鲁棒性** | `build_libvmpp_ohos.bat` + `scripts/CMakeLists.txt` | 每次构建前 `git checkout --` 恢复 Unicorn CMakeLists.txt 到原始状态，防止上次 ABI 的 patch 残留导致下次替换不匹配 |
| **MAP_32BIT** | native_dsm_funcs.c | `MAP_32BIT` 是 x86-glibc 专有，OHOS musl 缺失，x86_64 模拟器构建失败。替换为 0（有 calloc 兜底） |
| **case 800 ARM 地址修复** | mythroad.c + arm_ext_executor.c | 部分 MRP（如 3D暴力摩托）的 cfunction loader 把 ext 放在 ARM 内存并用 ARM 地址调 case 800。arm_ext_load 把 ARM 地址当 host 指针读取导致全 0 崩溃。检测到 ARM 地址时用 `arm_ext_host_ptr` 转成 host 指针 |

这些补丁只改 vmrp 子模块的工作区文件（构建时临时应用），不修改 vmrp 上游仓库。

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
scripts\build_libvmpp_ohos.bat vmrp x86_64   # 模拟器
```

### Q: 游戏启动后文字不显示
A: 检查工作目录设置。vmrp 的 `dsmWorkPath` 默认 `"mythroad/"`，chdir 目标必须是 mythroad 的**父目录**（即 files/），而非 mythroad 本身，否则字体路径 `mythroad/system/gb16.uc2` 会多嵌套一层。

### Q: 部分游戏启动失败返回列表
A: 这是 vmrp 对个别游戏的兼容性限制（如 3D暴力摩托）。vmrp 对每个游戏逐个逆向适配，未被适配的游戏（无 app_compat profile）可能无法运行。已适配的 dsm_gm、罪恶都市（gghjt）等可正常运行。

### Q: 游戏运行中触摸闪退
A: 已通过引擎锁（`engine_mtx_`）修复。若仍出现，确认 `vmrp_engine.cpp` 的 SendEvent/StepTimer 等方法都持有 `engine_mtx_` 锁。

---

## 许可

vmrp 源码遵循其原始许可（见 vmrp 子模块）。本移植工程的鸿蒙适配代码可自由使用。

## 致谢

- [vmrp](https://github.com/msojocs/vmrp) — MRP 模拟器核心
- [Unicorn Engine](https://www.unicorn-engine.org/) — 多架构 CPU 模拟框架
