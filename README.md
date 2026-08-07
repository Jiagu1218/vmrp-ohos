# 旧梦曲奇 (vmrp-ohos)

基于 [vmrp](https://github.com/msojocs/vmrp) 的 MRP 模拟器鸿蒙移植版。应用名「旧梦曲奇」（bundle `com.xjg.skyengine`），在鸿蒙手机/平板上运行功能机时代的 MRP 应用与游戏。

MRP（Mythroad）是斯凯平台的手机应用格式，其 `.mrp` 包内是 **ARM32 机器码**。本工程借助 Unicorn 引擎的 **arm-softmmu TCG 软件模拟**，在鸿蒙 ARM64/x86_64 设备上运行 ARM32 代码——**无需宿主机支持 ARM32**，符合鸿蒙不支持 ARM32 的约束。

> **TL;DR** — 在 DevEco Studio 打开本工程 → 预构建 libvmrp.so（JIT + TCI 双引擎）→ 编译运行即可在鸿蒙模拟器/真机上玩 MRP 游戏。

---

## 目录

- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [构建步骤详解](#构建步骤详解)
- [功能特性](#功能特性)
- [工程结构](#工程结构)
- [架构与关键技术](#架构与关键技术)
- [移植补丁说明](#移植补丁说明)
- [常见问题](#常见问题)

---

## 环境要求

以下软件**不入库**，需在其他电脑上自行安装：

| 软件 | 版本要求 | 用途 |
|------|---------|------|
| **DevEco Studio** | 含 HarmonyOS SDK API 23（HarmonyOS 6.1.0+） | 鸿蒙应用开发、编译、模拟器、签名 |
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

# 2. 预构建双引擎 libvmrp.so（需 Git for Windows 提供 POSIX sh）
#    每个 ABI 自动构建 JIT 版 (libvmrp.so) + TCI 版 (libvmrp_tci.so)
scripts\build_libvmpp_ohos.bat x86_64       # 模拟器
scripts\build_libvmpp_ohos.bat arm64-v8a    # 真机

# 3. 用 DevEco Studio 打开工程，或用 devecocli：
devecocli build
devecocli emulator start "Mate 70 RS"
devecocli run --device "Mate 70 RS"
```

启动后在首页游戏列表中点选 `.mrp` 进入模拟器页运行（内置 dsm_gm、gtgq 等示例游戏），也可通过系统文件管理器直接打开 `.mrp` 文件关联启动。

---

## 构建步骤详解

### 第一步：预构建双引擎 so

鸿蒙 native 模块（libentry.so）依赖预构建的引擎 so——它是 vmrp 核心 + Unicorn 交叉编译的产物。每个 ABI 构建 **两个变体**：

| 产物 | 引擎 | 说明 |
|------|------|------|
| `libvmrp.so` | **JIT**（TCG 动态翻译，全速） | 需要系统允许第三方分配 `PROT_EXEC` 内存（HarmonyOS 6.x 及以下） |
| `libvmrp_tci.so` | **TCI**（TCG 解释器，保底） | 不依赖 `PROT_EXEC`，HarmonyOS 7.0+（API 18+ 管控匿名内存执行权限）可用 |

运行时 `vmrp_engine.cpp` 先探测 `mmap(PROT_READ|WRITE|EXEC)` 能力：可执行 → 加载 JIT 版，否则加载 TCI 版；dlopen 失败还会尝试另一个（双保险）。运行界面会显示当前引擎模式（JIT/TCI）。

```bat
scripts\build_libvmpp_ohos.bat [abi]
```

- `abi`：`arm64-v8a`（真机，默认）或 `x86_64`（模拟器）

产物输出到：
- `entry\src\main\cpp\prebuilt\<abi>\libvmrp.so` + `libvmrp_tci.so`（CMake 链接用）
- `entry\libs\<abi>\libvmrp.so` + `libvmrp_tci.so`（HAP 打包用）

**同时构建两个 ABI**（真机 + 模拟器都支持）：
```bat
scripts\build_libvmpp_ohos.bat arm64-v8a
scripts\build_libvmpp_ohos.bat x86_64
```

> 脚本内部用 OHOS NDK 的 `ohos.toolchain.cmake` + Ninja 交叉编译，分两轮构建 `skyengine-shared` target（排除 main.c/e2e_control.c，不定义 VMRP_SDL_AUDIO，无 SDL 依赖）：轮 1 以 `OHOS_TCI_DISABLE=ON` 构建 JIT 版；轮 2 还原源码后以默认配置注入 TCI 后端构建 TCI 版。每轮结束 `:restore_patched` 把被补丁修改的文件恢复到提交状态。
> **注意**：vmrp 源码（`vmrp/`）已纳入本仓库版本管理，其 `third_party/unicorn` 是嵌套 git（由 vmrp-ohos 直接跟踪）。如需更新上游，在 `vmrp/` 内 `git pull` 后同步提交到本仓库。

### 第二步：构建鸿蒙工程

```bash
devecocli build
```

或在 DevEco Studio 中直接「Build → Build Hap(s)」。构建会：
1. 用 CMake 编译 `entry/src/main/cpp/` 为 `libentry.so`（NAPI 桥接层），**dlopen** 加载预构建的双 so + XEngine so（运行时加载，无链接期依赖），链接鸿蒙系统库（EGL/GLES/OHAudio/hilog）
2. 用 ArkTS 编译 UI 层
3. 打包成 HAP

### 第三步：运行

```bash
devecocli emulator start "Mate 70 RS"   # 启动模拟器
devecocli run --device "Mate 70 RS"      # 安装运行
```

真机（arm64）连接 USB 后同样用 `devecocli run --device <serial>`。

---

## 功能特性

### 模拟器核心
- **双引擎自适应**：JIT（全速）/ TCI（保底）运行时探测自动降级，运行界面显示引擎模式
- **XEngine AI 超分**：可选的 AI 画质增强（`libxengine.so` 运行时 dlopen，无链接期依赖，OpenHarmony 兼容）
- **模拟加速**：1x/2x/3x/4x 倍速切换
- **屏幕旋转**：LCD 旋转支持，触摸坐标自动反变换
- **显示滤镜**：亮度/对比度/饱和度/亚像素渲染/Gamma/抖动（Bayer）调节

### 交互
- 虚拟按键 + 数字键盘（PhoneControls）
- **手柄支持**：按键映射 + 摇杆 DPad + 斜角组合，3 套预设 + 自定义逐键映射（GamepadBinding）
- **重力感应**：加速度计 + 灵敏度/反转调节（已并入上游）
- 震动反馈：三档强度（轻柔/适中/强烈）
- 文本输入（editCreate）与**平台菜单/对话框**（menu/textCreate）自绘美化+触屏支持

### 游戏管理与 UI
- 首页 HdsTabs 沉浸光感底部导航：游戏库 / 收藏 / 设置
- 游戏列表：搜索、字母索引、拼音分组、下拉刷新、滑动删除、收藏（字母排序）
- 深色模式（跟随系统/手动切换）、中英文国际化
- 系统文件管理器 `.mrp` 文件关联打开
- 隐私合规弹窗 + 隐私政策（首次启动）

### 兼容性
- MUTICHANNEL 多声道音效 + IMA ADPCM 解码（修复游戏无声）
- 音频暂停/恢复/seek/进度查询，媒体状态回调
- 网络下载提速（DNS 修正 + select 超时优化）
- 平台菜单、WAP、支付等 MRP 平台接口

---

## 工程结构

```
vmrp-ohos/
├── vmrp/                          # vmrp 模拟器源码（纳入版本管理，上游 @b52bdbf）
│   └── third_party/unicorn/       #   Unicorn 引擎（嵌套 git，由 vmrp-ohos 直接跟踪）
├── ohos_src/                      # 鸿蒙专属源码（独立于 vmrp 树，避免上游冲突）
│   ├── ohos_image_decode.h/.cpp   #   SkyEngine 图片/GIF API 的鸿蒙原生实现
│   ├── native_text_widget.c/.h   #   平台文本框/对话框自绘美化+触屏（覆盖上游）
│   └── native_modal_menu.c/.h    #   平台菜单自绘美化+触屏（覆盖上游）
├── docs/                          # 补丁/功能/调研文档（见下文文档清单）
├── scripts/                       # 预构建脚本
│   ├── build_libvmpp_ohos.bat     #   双引擎 so 交叉编译入口
│   ├── CMakeLists.txt             #   CMake wrapper（含移植补丁）
│   └── test_op6120.sh / test_cookie_submrp.sh   # 兼容性测试脚本
├── entry/                         # 鸿蒙 entry 模块
│   ├── src/main/cpp/              # Native 桥接层（C++）
│   │   ├── vmrp_napi.cpp          #   NAPI 入口（XComponent + 事件 + 弹窗回调）
│   │   ├── vmrp_engine.cpp/.h     #   dlopen 双 so + PROT_EXEC 探测 + 引擎锁
│   │   ├── vmrp_renderer.cpp/.h   #   XComponent + EGL/GLES 渲染 + XEngine dlopen
│   │   ├── vmrp_audio.cpp/.h      #   OHAudio 拉流
│   │   ├── include/skyengine_api.h #   skyengine C ABI（40+ 导出，无 SDL）
│   │   ├── types/libentry/Index.d.ts  # NAPI 类型声明
│   │   ├── prebuilt/<abi>/        #   libvmrp.so + libvmrp_tci.so（构建生成）
│   │   └── CMakeLists.txt         #   native 构建
│   ├── src/main/ets/              # ArkTS UI 层
│   │   ├── pages/Index.ets        #   首页（HdsTabs：游戏库/收藏/设置）
│   │   ├── pages/Emulator.ets     #   模拟器页（XComponent + 键盘 + 手柄 + 菜单/编辑弹窗）
│   │   ├── pages/Settings.ets     #   设置页（内存/动感/震动/滤镜/引擎/主题/语言）
│   │   ├── components/            #   EmulatorControls/GamepadBinding/GamepadHelpers/SettingsControls/PrivacyDialog
│   │   ├── model/                 #   MrpListModel/FavoriteStore
│   │   ├── common/                #   GlassPanel/HapticManager/ImmersiveLightWrapper/AvoidData 等
│   │   ├── vmrp/                  #   VmrpEngine.ets/VmrpAssets.ets/MrpInfo.ets
│   │   └── entryability/          #   EntryAbility（含 .mrp 文件关联处理）
│   ├── src/main/resources/rawfile/mythroad/  # 内置运行时（dsm_gm.mrp 等 + 字体）
│   ├── libs/<abi>/                # 双 so 打包位置（构建生成）
│   ├── build-profile.json5        # externalNativeBuild + abiFilters
│   └── module.json5               # 权限（网络/震动/加速度计）+ 文件关联
├── build-profile.json5            # 工程级构建配置
├── oh-package.json5               # 工程依赖
└── README.md                      # 本文件
```

### 文档清单（docs/）

| 文档 | 内容 |
|------|------|
| `tci-interpreter-port.md` | TCI 解释器移植（绕过 HarmonyOS 7.0 PROT_EXEC 限制） |
| `harmonyos7-execmem-issue.md` | HarmonyOS 7.0 PROT_EXEC 管控调研 |
| `split-wx-jit-research.md` | Split-WX JIT 方案调研（替代 TCI 的潜在方案） |
| `skyengine-image-api.md` | SkyEngine 图片/GIF 接口适配 |
| `platex-memory-extension.md` | SkyEngine 内存扩展接口适配 |
| `exception-heap-recovery.md` | UC_ERR_EXCEPTION 堆数据恢复 |
| `mutichannel-audio-fix.md` | MUTICHANNEL 多声道音频 + IMA ADPCM |
| `network-download-speedup.md` | 网络下载提速优化 |
| `menu-platform-known-issue.md` | 平台菜单实现 + 已知问题 |
| `hds-navigation-immersive-guide.md` | HdsNavigation/HdsTabs 沉浸光感避让实战 |
| `immersive-layout-guide.md` | 沉浸式布局知识与经验 |
| `mtk_disasm/` | MTK 平台 mythroad 反汇编参考资料 |

---

## 架构与关键技术

### 整体架构

```
HarmonyOS App（旧梦曲奇）
├── ArkTS UI（首页 HdsTabs + 模拟器页 XComponent + 虚拟键盘/手柄 + 菜单/编辑弹窗 + 设置）
├── Native 桥接（libentry.so）
│   ├── NAPI：init/start/stop/sendKey/sendMotion/submitEdit/startDsmB/C/ex 等 40+
│   ├── EGL/GLES：RGB565 直传纹理渲染（XComponent 帧回调线程）
│   ├── OHAudio：pull 模型 PCM 拉流（音频回调线程）
│   ├── XEngine：运行时 dlopen libxengine.so（AI 超分）
│   └── 定时器驱动：timer loop 按间隔调度 skyengine_api_timer
│       ↓ skyengine_api.h（40+ 个 C 函数，无 SDL）
└── 引擎 so（运行时二选一 dlopen）
    ├── libvmrp.so      — JIT：Unicorn TCG 动态翻译（需 PROT_EXEC）
    ├── libvmrp_tci.so  — TCI：TCG 解释器（HarmonyOS 7.0+ 保底）
    ├── vmrp 核心 + mythroad DSM 层
    ├── arm_ext_executor：Unicorn 执行 ARM ext
    ├── ohos_image_decode：鸿蒙原生图片/GIF 解码（Image C API）
    ├── native_text_widget：平台文本框/对话框自绘美化+触屏（覆盖上游）
    ├── native_modal_menu：平台菜单自绘美化+触屏（覆盖上游）
    └── unicorn arm-softmmu：TCG 软件模拟 ARM32
```

### 关键技术点

1. **arm-softmmu 是纯软件 TCG 模拟**：把 ARM32 指令翻译成宿主机指令执行，不依赖宿主 ARM32 硬件。因此在 ARM64/x86_64 鸿蒙上都能跑 MRP 的 ARM32 代码。

2. **双引擎 so（JIT/TCI）**：HarmonyOS 7.0（API 18+）实施匿名内存执行权限管控，禁止第三方分配 `PROT_EXEC` 内存，JIT 的 TB cache 无法分配导致启动即崩。移植 QEMU TCI 解释器后端（`docs/tci-interpreter-port.md`）作为保底：运行时 `mmap(PROT_READ|WRITE|EXEC)` 探测 + dlopen 失败双保险，无缝降级。TCI 性能约为 JIT 的 1/5~1/10，MRP 低速业务可接受。Split-WX JIT 方案已实机验证不可行（`mmap(fd, PROT_EXEC)` 返回 EACCES，详见 `docs/split-wx-jit-research.md`）。

3. **vmrp 已有 SDL-free 共享库 API**（`skyengine_api.h`，40+ 个导出函数）：构建 `skyengine-shared` target 即可，不含 main.c，不定义 `VMRP_SDL_AUDIO`。这是移植的核心入口。

4. **XEngine AI 超分运行时加载**：`libxengine.so` 通过 `dlopen` 在渲染初始化时探测加载（25082a9 移除链接期依赖，兼容无 XEngine 的 OpenHarmony 设备），加载失败自动回落原始滤镜管线。

5. **渲染线程模型**：EGL surface 必须在 XComponent 帧回调线程（创建 surface 的同线程）渲染，否则 `eglSwapBuffers` 报 `EGL_BAD_SURFACE`。用 `OH_NativeXComponent_RegisterOnFrameCallback` 注册帧回调，在该线程做 `eglSwapBuffers`。渲染管线经过多轮优化：**RGB565 直传 GPU**（省去 RGB565→RGBA8888 转换 + 减半上传带宽）、**dirty 跳帧 + PBO 异步上传 + bypass 直通 pass**、**Bayer 抖动移到 Postproc shader**（RGB565 直传路径下恢复生效）。

6. **像素对齐**：MRP 屏幕 240×320 → XComponent surface（可旋转）。`glViewport` 用 `eglQuerySurface` 获取的 surface 实际尺寸铺满；纹理过滤用 `GL_NEAREST` 保持像素艺术清晰。

7. **引擎单线程约束**：Unicorn ARM 引擎不支持并发。触摸线程的 `SendEvent` 和 timer 线程的 `StepTimer` 都会调 `uc_emu_start`。用 `std::mutex engine_mtx_` 串行化所有驱动 Unicorn 的调用，否则 TCG 的 TB cache 损坏导致 `translate-all.c g_assert_not_reached`（UC_ERR_EXCEPTION）闪退。

8. **音频 pull 模型**：`skyengine_api_audio_render_s16le(buf, frames)` 由宿主拉取 PCM，与 OHAudio 的 WriteData 回调天然匹配。44100Hz/2ch/S16LE。MUTICHANNEL 多声道音效 + IMA ADPCM 解码由补丁 `OHOS_MUTICHANNEL_DISPATCH` + `OHOS_IMA_ADPCM` 实现（见 `docs/mutichannel-audio-fix.md`）。

9. **stdio→hilog 重定向**：vmrp 核心全用 `printf`/`fprintf`，鸿蒙下默认不进 hilog。在 `VmrpEngine::Load` 把 stdout/stderr 重定向到 pipe，读线程转发到 hilog，使崩溃信息、mr_open 等日志可见。

10. **SkyEngine 图片/GIF 解码**：使用鸿蒙原生 `OH_ImageSourceNative`/`OH_PixelmapNative` C API 解码图片（PNG/JPG→RGB565）和 GIF 多帧动画。GIF 动画由 `ohos_gif_tick()` 在 `mr_timer()` 内驱动，保证帧推进与 vmrp worker 线程串行，避免并发写 `mr_screenBuf`。详见 [docs/skyengine-image-api.md](docs/skyengine-image-api.md)。

11. **平台 UI 美化+触屏**：上游 `native_text_widget.c`/`native_modal_menu.c` 走黑底绿字自绘 + 按键操作。OHOS 树外覆盖版（`ohos_src/`）在上游机制基础上（镜像截留/filter_event/transition 全保留）增加：渐变标题栏/软键栏、选中项反白文字、`NativeWidgetTheme` 主题系统、`filter_event` 加 p1 参数支持触屏 hit-test（点击菜单项直接选中、点击软键栏确认/取消、滚动条拖拽）。上游 b52bdbf 已吸收 modal_menu 的 p1 触屏支持。

12. **上游同步策略**：vmrp 上游频繁演进，本仓库定期 `sync: upstream` + 重建双 so；已被上游吸收的补丁随同步移除。当前上游基线 @b52bdbf。vmrp 子模块零修改——所有 OHOS 改动通过构建期 `file(COPY)` 覆盖 + `string(REPLACE)` 补丁注入，构建后 `:restore_patched` 还原。

### 数据流

```
触摸事件 ──→ XComponent 触摸回调 ──→ SendEvent (加锁) ──→ skyengine_api_event ──→ ARM 事件处理
                                                                                        ↓
重力感应 ──→ OH_Sensor 回调 ──→ 异步队列 ──→ skyengine_api_motion ──→ ARM 重力处理
                                                                                        ↓
定时器线程 ──→ StepTimer (加锁) ──→ skyengine_api_timer ──→ ARM 定时器逻辑 ──→ 绘图到 screen_buf
                                                                                        ↓                                     ↓
                                                          ohos_gif_tick() ──→ GIF 帧推进 ──→ RGB565 写入 screen_buf
                                                                                        ↓
XComponent 帧回调 ──→ ScreenBuffer (RGB565) ──→ RGB565 直传 EGL/GLES ──→ (可选 XEngine 超分) ──→ eglSwapBuffers ──→ 屏幕
                                                                                        ↓
OHAudio 回调线程 ──→ PullAudio (不加锁) ──→ skyengine_api_audio_render_s16le ──→ PCM ──→ 扬声器

图片/GIF 解码路径：
MRP 调 mr_plat(300x) ──→ dsm.c ──→ ohos_image_decode ──→ OH_ImageSourceNative ──→ RGB565 ──→ mr_screenBuf

菜单/对话框路径（自绘+触屏）：
MRP 调 table[63-68]/table[69-74] ──→ native_modal_menu/native_text_widget 自绘渲染 ──→ guiDrawBitmap 上屏
                                                              ↑
                    触屏点击 ──→ filter_event hit-test ──→ event(MR_MENU_SELECT/RETURN 或 MR_DIALOG_EVENT)
```

---

## 移植补丁说明

构建脚本 `scripts/CMakeLists.txt` 在 `add_subdirectory(vmrp)` 前会自动应用以下补丁（幂等，可重复运行）。所有补丁通过标记字符串（如 `OHOS_ARM_ADDR_FIX`）检测是否已应用，支持增量构建；构建结束后由 `:restore_patched` 恢复到提交状态。

### 为什么 OHOS 需要这些补丁而上游不需要

上游 vmrp 基于 **SDL 单线程模型**：主循环在一个线程里串行处理定时器、输入、渲染和引擎逻辑。单次 dispatch 失败只丢一个 tick，`while` 循环自然容错继续运行。

OHOS 必须**分离 UI 线程和引擎 Worker 线程**——ArkUI 要求主线程 16ms 内完成帧渲染，而 Unicorn 模拟一次 `arm_ext_call` 可能耗时数十毫秒，放主线程会冻屏。分离后 Worker 是引擎的唯一驱动者：dispatch 失败 → timer 停摆 → 不再产生新事件 → 游戏永久冻结。因此 OHOS 的核心容错原则是 **"让 dispatch 永远干净返回，绝不中断 Worker 事件循环"**。

此外，OHOS/musl 的内存映射与 Linux/glibc 不同：Unicorn 无法在低地址做 `MAP_FIXED`，ARM 虚拟地址不再等于 host 指针地址，需要显式地址翻译；内存越界写入可能不触发 SIGSEGV 而是静默损坏其他数据。

### 基础移植补丁

| 幂等标记 | 文件 | 原因 |
|---------|------|------|
| (无标记) | unicorn/CMakeLists.txt | **/dev/null 探测**：Windows 宿主下 `/dev/null` 不存在，Unicorn 主机架构探测失败。改为空字符串输入 |
| (无标记) | unicorn/CMakeLists.txt | **--cc wrapper**：OHOS clang 是交叉编译器，裸调用不带 `--target` 导致 `qemu/configure` 误判宿主为 mingw32。用 sh wrapper 注入 `--target`/`--sysroot`；`string(REGEX REPLACE)` 匹配任意已有 wrapper 路径，支持跨 ABI 交替构建 |
| (无标记) | unicorn/CMakeLists.txt | **TCG 架构检测**：Windows 下 OHOS clang 默认 x86_64，`__x86_64__` 被定义 → `UNICORN_TARGET_ARCH=i386` → 编译错误的 TCG 后端。用 `.bat` wrapper 替代裸 clang |
| (无标记) | native_dsm_funcs.c | **MAP_32BIT**：x86-glibc 专有，OHOS musl 缺失，x86_64 模拟器构建失败。替换为 0（有 calloc 兜底） |
| `OHOS_MEM_MMAPED` | native_dsm_funcs.c | **内存释放方式判断**：去掉 MAP_32BIT 后 mmap 返回高地址（>0x80000000），原实现按地址范围猜分配方式，`free(mmap'd ptr)` 触发 SIGSEGV。加 mmaped 标志位，按来源 munmap/free |

### TCI 解释器（双 so）

| 幂等标记 | 文件 | 功能 |
|---------|------|------|
| `OHOS_TCI` | unicorn qemu/configure + tcg.h + tcg.c + 新增 tci.c/tci/ | **TCI 解释器后端移植**：HarmonyOS 7.0 禁止第三方 `PROT_EXEC` 内存，JIT 的 TB cache 无法分配。移植 QEMU TCG 解释器（纯 C 字节码解释执行），不分配可执行内存。详见 [docs/tci-interpreter-port.md](docs/tci-interpreter-port.md) |
| `OHOS_TCI_DISABLE` | 构建开关 | **双 so 构建**：OFF（默认）注入 TCI 后端 → `libvmrp_tci.so`；ON 跳过 → `libvmrp.so`（JIT）。构建脚本两轮产出两个 so，运行时探测选择 |

### 稳定性修复补丁

| 幂等标记 | 文件 | 原因 |
|---------|------|------|
| `OHOS_MEMSET_BOUNDS_GUARD` | aex_table.c | **memset 越界守卫**（case 38）：`arm_alloc` 的长度守卫不覆盖 `heap_top` 被踩为异常小值场景。上游 Linux/glibc 下 memset 越界立即 SIGSEGV 被 Unicorn hook 捕获走优雅退出；OHOS/musl 可能不触发 SIGSEGV 而静默损坏后续数据 |
| `OHOS_UNMAPPED_GRACEFUL_EXIT` | arm_ext_executor.c + aex_exec.c | **WRITE 黑洞页 + READ/INSN/EXCEPTION 优雅退出**：① WRITE_UNMAPPED：上游 hook_invalid 返回 false → `uc_emu_start` 报错 → 丢 tick。OHOS Worker 线程丢 tick 后永久冻结；改为动态 `uc_mem_map` 64K 黑洞页让写操作真正完成，guest 状态一致不会循环崩溃。② READ_UNMAPPED/INSN_INVALID/EXCEPTION：设 `PC=EXT_STOP_ADDR` + TB flush，返回 MR_SUCCESS 让 Worker 继续处理下一个命令 |
| `OHOS_EXCEPTION_HEAP_RECOVERY` | aex_exec.c | **EXCEPTION 堆数据恢复**：OHOS/musl 内存布局下堆损坏更常触发 UC_ERR_EXCEPTION（如 BLX 跳到损坏的返回地址落在数据区），需要恢复堆上的 R9/栈等关键数据。详见 [docs/exception-heap-recovery.md](docs/exception-heap-recovery.md) |
| `OHOS_EXT_STOP_HOOK` | arm_ext_executor.c | **EXT_STOP_ADDR hook**：统一拦截 ext 停止地址，与 graceful exit 配合保证 Worker 事件循环不中断 |

### 功能扩展补丁

| 幂等标记 | 文件 | 功能 |
|---------|------|------|
| `OHOS_ARM_ADDR_FIX` + `arm_ext_host_ptr` | mythroad.c + arm_ext_executor.c | **case 800 ARM 地址修复**：部分 MRP（如 3D暴力摩托）的 cfunction loader 把 ext 放在 ARM 内存并用 ARM 地址调 case 800。上游 Linux/glibc 下 Unicorn 用 `MAP_FIXED` 使 guest 地址=host 地址，直接解引用正确；OHOS/musl 无法 MAP_FIXED，需 `arm_ext_host_ptr(m, addr)` = `m->mem + (addr - EXT_BASE_ADDR)` 翻译为 host 指针 |
| `OHOS_PLATEX_MEM_EXT` + `OHOS_PLATEX_IRAM` | aex_table.c | **内存扩展**：platEx(1001) 屏幕缓冲（第二内存）、platEx(1012) 内部 cache（IRAM）——ARM 堆分配，guest 通过写回的 ARM 地址访问。详见 [docs/platex-memory-extension.md](docs/platex-memory-extension.md) |
| `OHOS_GIF_TICK` | mythroad.c | `mr_timer()` 末尾注入 `ohos_gif_tick()` 推进 GIF 动画帧，保证与 mr_screenBuf 写入串行 |
| `OHOS_ENTRY_CALL` | mythroad.c | dofile 后显式调用 `_mr_entry` 指向的入口函数（恢复上游 b82dd68 修复，上游升级时丢失） |
| `OHOS_DSM_BC_EX` | mythroad.c + skyengine_api.c | `mr_start_dsmB(entry)` / `mr_start_dsmC(entry)` / `mr_start_dsm_ex(path, entry)` 外部移植接口 |
| `OHOS_FILTER_P1` | runtime_native_mythroad.c | **text_widget filter 传 p1**：上游 b52bdbf 已改 modal_menu filter 传 p1，text_widget filter 仍需补丁加 p1（触屏 y 坐标） |
| `OHOS_MEDIA_CTRL`/`OHOS_MEDIA_API`/`OHOS_MEDIA_DECL`/`OHOS_DSM_MEDIA` | native_dsm_funcs.c + dsm.c + skyengine_api.h/.c | **媒体控制**：音频 pause/resume/seek/position/duration + 暂停渲染跳过 + 播放回调（停启 OHAudio renderer）+ MR_MEDIA_SETPOS(210)/GET_TOTAL_TIME(212)/GET_CURTIME(213)/GET_CURTIME_MSEC(215) |
| `OHOS_SET_VOL` | dsm.c | `mr_plat(MR_SET_VOL=1302)` 音量控制：`param`(0~10) → `skyengine_api_set_volume` → 宿主调 `OH_AudioRenderer_SetVolume`，不做软件 PCM 缩放避免双算 |
| `OHOS_SUBV_ARM_PTR` + `OHOS_SUBV_GETNATEXT` | dsm.c + network.c | **string.subV 64 位指针截断修复**：Lua 字符串内部 C 指针返回给 Lua 层时被 32 位截断；`getNAText` 同理。ARM 地址需经 `arm_ext_host_ptr` 翻译 |
| `OHOS_NET_SPEEDUP` | network.c | **网络提速**：select 超时 50ms→5ms + printf→VMRP_NET_LOG + proxy.51mrp.com DNS 修正。详见 [docs/network-download-speedup.md](docs/network-download-speedup.md) |
| `OHOS_SPEED_MULT`/`OHOS_SPEED_DECL` | skyengine_api.c/h | 模拟加速 1x-4x 倍速（timer 间隔缩放） |

> 已并入上游、随同步移除的补丁：重力感应（`OHOS_MOTION_*`）、震动（`OHOS_SHAKE`）、音量（`OHOS_VOLUME_*`）、`OHOS_TIMER_OWNER_FIX`（上游 f619149 删除了 `primary_resume_without_timer_owner`）、`OHOS_MENU_*`（上游 4e8b93a 实现了平台菜单）、`OHOS_TEXTWIDGET_BEAUTIFY`（改为树外覆盖）、MIDI 事件上限等。

### 鸿蒙专属源码（ohos_src/）

不在 vmrp 源码树内，由 CMake 单独编译链接，避免上游合并冲突：

| 文件 | 功能 |
|------|------|
| `ohos_image_decode.cpp` | SkyEngine 图片/GIF API 的鸿蒙原生实现。使用 `OH_ImageSourceNative`/`OH_PixelmapNative`（鸿蒙 Image C API），支持 PNG/JPG 解码为 RGB565、GIF 多帧解码与动画播放、DMA 刷屏、直接绘制 |
| `native_text_widget.c/.h` | 平台文本框/对话框自绘美化版（覆盖上游）：渐变标题栏/软键栏、`NativeWidgetTheme` 主题系统、粗体标题、圆角滚动条、filter_event p1 触屏 hit-test |
| `native_modal_menu.c/.h` | 平台菜单自绘美化版（覆盖上游）：渐变标题栏/软键栏、选中项反白文字、filter_event p1 触屏 hit-test（含上游 b52bdbf 的 DOWN→UP 手势追踪） |

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

> 这些补丁在构建时临时应用到 vmrp 源码的工作区文件，每次构建前后由 `:restore_patched` 恢复，不残留。需持久保留的改动应直接提交到本仓库的 `vmrp/` 目录。

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
A: 模拟器是 x86_64，真机是 arm64。需构建对应 ABI 的 so：
```bat
scripts\build_libvmpp_ohos.bat x86_64   # 模拟器
```

### Q: HarmonyOS 7.0 / API 18+ 设备上启动即闪退
A: 这是系统禁止第三方分配 `PROT_EXEC` 内存导致 JIT 崩溃。双 so 方案已解决：运行时探测失败会自动加载 TCI 解释器版（`libvmrp_tci.so`），不依赖可执行内存。若仍闪退，查看 hilog 中是否两个 so 都 dlopen 失败。详见 [docs/tci-interpreter-port.md](docs/tci-interpreter-port.md)。

### Q: 运行界面显示「引擎模式」是什么
A: 当前加载的引擎变体：**JIT**（TCG 动态翻译，全速，需要系统允许可执行内存）或 **TCI**（TCG 解释器，保底，约 1/5~1/10 性能）。正常情况两者皆可运行 MRP；低速游戏（文字游戏等）在 TCI 下也流畅。

### Q: 游戏启动后文字不显示
A: 检查工作目录设置。vmrp 的 `dsmWorkPath` 默认 `"mythroad/"`，chdir 目标必须是 mythroad 的**父目录**（即 files/），而非 mythroad 本身，否则字体路径 `mythroad/system/gb16.uc2` 会多嵌套一层。

### Q: 部分游戏启动失败返回列表
A: 这是 vmrp 对个别游戏的兼容性限制（如 3D暴力摩托）。vmrp 对每个游戏逐个逆向适配，未被适配的游戏（无 app_compat profile）可能无法运行。已适配的 dsm_gm、罪恶都市（gghjt）等可正常运行。

### Q: 游戏运行中触摸闪退
A: 已通过引擎锁（`engine_mtx_`）修复。若仍出现，确认 `vmrp_engine.cpp` 的 SendEvent/StepTimer 等方法都持有 `engine_mtx_` 锁。

### Q: 游戏画面花屏/卡死
A: 已通过 `OHOS_UNMAPPED_GRACEFUL_EXIT` 补丁修复——WRITE_UNMAPPED 动态映射黑洞页让写操作完成保持 guest 状态一致，READ/INSN/EXCEPTION 设 PC=STOP 优雅退出当前 dispatch。若仍出现，可能是 MRP 应用的绘图指令超出了屏幕缓冲区范围（见 `OHOS_MEMSET_BOUNDS_GUARD`）。

### Q: 游戏运行一段时间后定时器停了
A: 已通过 `OHOS_UNMAPPED_GRACEFUL_EXIT` + `OHOS_EXCEPTION_HEAP_RECOVERY` 补丁修复——UC_ERR_EXCEPTION 后恢复堆上 R9/栈等关键数据，graceful exit 让 Worker 继续处理下一个命令。若仍出现，查看 hilog 中 `vmrp_core:` 标签的日志。

### Q: 游戏中图片不显示
A: SkyEngine 图片 API（3001-3012）已实现。若图片仍不显示，可能是 MRP 使用了 3014/3015（MTK 私有资源格式，暂未实现），或图片文件路径无法通过 `mr_open` 访问。

### Q: 游戏中没有音效
A: 多数无声问题由 MUTICHANNEL 多声道 API（mr_platEx 2222/2232/2242/2252）未实现导致，已通过 `OHOS_MUTICHANNEL_DISPATCH` + `OHOS_IMA_ADPCM` 补丁修复。详见 [docs/mutichannel-audio-fix.md](docs/mutichannel-audio-fix.md)。

### Q: 平台菜单/对话框不弹出
A: 平台菜单（table[62-68]）和文本框/对话框（table[69-74]）由上游实现，OHOS 通过 `ohos_src/` 树外覆盖美化（渐变+触屏）。构建时 `file(COPY)` 覆盖上游 .c/.h，构建后 `:restore_patched` 还原。

### Q: vmrp/ 目录下显示有未提交的修改
A: 不应出现。构建补丁在构建时临时修改 vmrp 源码，构建后由 `:restore_patched` 用 `git checkout` 还原全部。如果仍有残留，手动执行 `cd vmrp && git checkout -- .` 即可。vmrp 子模块应始终与上游基线一致（零修改）。

---

## 许可

vmrp 源码遵循其原始许可（见 [vmrp](https://github.com/msojocs/vmrp) 上游）。本移植工程的鸿蒙适配代码可自由使用。

## 致谢

- [vmrp](https://github.com/msojocs/vmrp) — MRP 模拟器核心
- [Unicorn Engine](https://www.unicorn-engine.org/) — 多架构 CPU 模拟框架
- [chashaochang/unicorn-ohos](https://github.com/chashaochang/unicorn-ohos) — Split-WX JIT 方案参考（docs/split-wx-jit-research.md）
