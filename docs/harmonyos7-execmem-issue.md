# HarmonyOS 7.0 相对于 6.1 是否禁用了第三方应用分配可执行内存(PROT_EXEC)的能力？

## 基本信息

| 项目 | 内容 |
|------|------|
| **工单类型** | 系统兼容性 / 开发者能力受限 |
| **项目名称** | vmrp-ohos（基于 Mythroad 平台的 MRP 应用模拟器） |
| **项目地址** | https://github.com/Jiagu1218/vmrp-ohos |
| **应用包名** | com.xjg.skyengine |
| **签名类型** | Debug 自动签名（AGC 注册） |

## 设备信息

| 项目 | 内容 |
|------|------|
| **机型** | HUAWEI Mate 70 Pro（PLR-AL00） |
| **系统版本** | HarmonyOS 7.0.100（Build: PLR-AL00 7.0.0.100(SP8C00E32R5P4)） |
| **之前版本** | HarmonyOS 6.1（OpenHarmony-6.1.0.115，API 23，正常运行） |
| **GPU** | Maleoon 920 |
| **GLES 版本** | OpenGL ES 3.2 |

## 问题描述

我们开发了一款基于 Unicorn（QEMU TCG JIT 编译器）的 ARM 指令模拟器应用。该应用在 **HarmonyOS 6.1 上完全正常运行**，但用户设备升级到 **HarmonyOS 7.0 后，应用启动即崩溃（exit(1)）**，完全无法使用。

**根本原因**：Unicorn 引擎依赖 TCG（Tiny Code Generator）JIT 编译器，需要通过 `mmap` 分配一块**可执行内存（`PROT_READ | PROT_WRITE | PROT_EXEC`）**作为动态代码翻译缓存。HarmonyOS 7.0 在**系统调用层面（mmap/mprotect）禁止了第三方应用进程获取任何含 `PROT_EXEC` 的内存**，导致 JIT 编译器无法分配代码缓存，初始化失败，应用无法运行。

> **注意**：这不是针对 JIT 功能的检测/禁用，而是系统调用层面 `PROT_EXEC` 权限的限制。JIT 编译器需要可执行内存来写入和运行翻译后的机器码，禁止 `PROT_EXEC` 等于釜底抽薪切断了 JIT 的工作基础。
>
> HarmonyOS 6.1 **没有此限制**——`mmap(PROT_READ|PROT_WRITE|PROT_EXEC)` 直接成功，应用正常运行。
> 系统自身的 ArkCompiler JIT 在 7.0 上仍正常工作（日志中可见 `__jit_debug_register_code()` 调用），说明**系统进程/框架仍保留 execmem 权限**，仅第三方应用的原生代码(NDK .so)被限制。

## 复现步骤

1. 在 HarmonyOS 7.0 设备上安装应用
2. 启动应用，尝试加载任何游戏/功能
3. 应用在引擎初始化阶段崩溃，日志输出 `Could not allocate dynamic translator buffer`，然后 `exit(1)`

## 崩溃日志

```
Reason: Signal:SIGABRT(SI_TKILL)@0x01317c9400001aad from:6829:20020372
LastFatalMessage: [appspawn_server.c:69]Unexpected call: exit(1)

Fault thread info:
Tid:6829, Name:xample.vmrpohos
#00 pc 0x1c3974 /system/lib/ld-musl-aarch64.so.1(raise+216)
#01 pc 0x16c408 /system/lib/ld-musl-aarch64.so.1(abort+24)
#02 pc 0x1abc   /system/lib64/libappspawn_helper.z.so(exit+144)
#03 pc 0x147524 libvmrp.so(tcg_exec_init_arm+452)
#04 pc 0x1338fc libvmrp.so(machine_initialize+88)
#05 pc 0x12fb10 libvmrp.so(uc_init_engine)
#06 pc 0x1314d0 libvmrp.so(uc_mem_map_ptr+512)
#07 pc 0xc3f4c  libvmrp.so(arm_ext_load)
...（中间为应用调用栈）...
#21 pc 0xb0ad8  libvmrp.so(skyengine_api_start+388)
```

**崩溃位置**：`tcg_exec_init_arm` → `code_gen_alloc` → `alloc_code_gen_buffer` → `mmap(PROT_RWX)` 返回 `MAP_FAILED` → `exit(1)`

源码位置：`third_party/unicorn/qemu/accel/tcg/translate-all.c:1086`

```c
// Unicorn JIT 需要分配可执行内存作为代码翻译缓存
static inline void *alloc_code_gen_buffer(struct uc_struct *uc)
{
    int prot = PROT_WRITE | PROT_READ | PROT_EXEC;
    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
    buf = mmap(NULL, size, prot, flags, -1, 0);
    if (buf == MAP_FAILED) {
        // ← HarmonyOS 7.0 上走到这里
        return NULL;
    }
    ...
}

// 调用方检查到 NULL 后 exit(1)
if (tcg_ctx->code_gen_buffer == NULL) {
    fprintf(stderr, "Could not allocate dynamic translator buffer\n");
    exit(1);  // ← 崩溃点
}
```

## 测试数据（4 种方式全部被拒绝）

我们在应用中编写了最小化测试代码，在 HarmonyOS 7.0 上尝试 4 种方式获取可执行内存，**全部失败**：

| # | 测试方式 | 结果 | 错误码 |
|---|---------|------|--------|
| 1 | `mmap(NULL, 4096, PROT_READ\|PROT_WRITE\|PROT_EXEC, MAP_PRIVATE\|MAP_ANONYMOUS, -1, 0)` | **FAIL** | EINVAL(22) |
| 2 | `mmap(PROT_RW)` + `mprotect(buf, 4096, PROT_RWX)` | **FAIL** | EINVAL(22) |
| 3 | `mmap(PROT_RW)` + `mprotect(buf, 4096, PROT_READ\|PROT_EXEC)` (W^X) | **FAIL** | EINVAL(22) |
| 4 | `mmap(NULL, 4096, PROT_EXEC, MAP_PRIVATE\|MAP_ANONYMOUS, -1, 0)` (纯 EXEC) | **FAIL** | EINVAL(22) |

### 额外尝试的绕过方案（同样失败）

| 方案 | 结果 | 详情 |
|------|------|------|
| **memfd_create + mmap** | FAIL | `memfd_create` 成功（返回 fd=51），但 `mmap(PROT_RWX)` 和 `mprotect(PROT_EXEC)` 均返回 EACCES(13) |
| **直接 syscall(SYS_mmap=222, PROT_RWX)** | FAIL | 绕过 musl libc wrapper 直接调内核，仍然 EINVAL(22) |
| **直接 syscall(SYS_mprotect=226, RWX)** | FAIL | 绕过 musl libc wrapper，仍然 EINVAL(22) |
| **减小 buffer 到 32MB** | FAIL | 从默认 1GB 减到 32MB，仍然失败 |
| **Debug 签名** | FAIL | Debug 自动签名同样被拒绝 |

### 对比：HarmonyOS 6.1 上的测试结果（全部成功）

| 测试方式 | 结果 |
|---------|------|
| `mmap(PROT_RWX)` | **OK** ✓ |
| `mmap(PROT_RW)` + `mprotect(PROT_RWX)` | **OK** ✓ |

**结论**：这是 HarmonyOS 7.0 新增的安全策略，6.1 没有此限制。

## 影响范围

这不只影响单个功能，而是**应用完全无法运行**。Unicorn JIT 是应用的核心引擎：
- 没有可执行内存 → 没有 JIT 编译 → 无法翻译 ARM 指令 → 模拟器无法工作

### 同类受影响的应用类型

| 应用类型 | 代表技术 | JIT 依赖 |
|---------|---------|---------|
| **模拟器/虚拟机** | Unicorn, QEMU, 动态二进制翻译器 | 需要 PROT_EXEC 做 JIT 代码缓存 |
| **JS/TS 运行时** | V8 JIT, JavaScriptCore, Hermes | 需要 PROT_EXEC 做即时编译 |
| **.NET 运行时** | .NET Native JIT, Mono JIT | 需要 PROT_EXEC |
| **Java 字节码 JIT** | OpenJDK HotSpot (如果移植到 OHOS) | 需要 PROT_EXEC |
| **动态代码生成** | 反编译器、调试器、DSL 解释器 | 需要 PROT_EXEC |

## 期望的解决方案

请提供以下任一方案，使我们能在 HarmonyOS 7.0 上获取可执行内存：

### 方案 1：受限权限申请通道（推荐）

类似 iOS 的 `com.apple.security.cs.allow-jit` entitlement 机制：
- 开发者在 AGC 申请"可执行内存"受限权限
- 提交使用场景说明和审核材料
- 审核通过后，应用获得 execmem 权限
- 在 `module.json5` 中声明，运行时由系统放行

### 方案 2：官方 W^X JIT 内存 API

类似 macOS/iOS 的 `pthread_jit_write_protect_np()` 方案：
- 提供 API 创建 W^X（Write XOR Execute）内存
- 写入代码时切换为 RW，执行时切换为 RX
- 既满足 JIT 需求，又不破坏 W^X 安全模型

```c
// 期望的 API 示例
void *buf = ohos_jit_memory_allocate(size);  // 分配 W^X 内存
ohos_jit_write_begin(buf);                    // 切换为可写
memcpy(buf, jit_code, code_size);            // 写入 JIT 代码
ohos_jit_write_end(buf);                     // 切换为可执行
((void(*)())buf)();                           // 执行
```

### 方案 3：开放 SELinux execmem 策略

如果限制来源是 SELinux execmem 策略：
- 通过 AGC 申请受限权限证书解除 execmem 限制
- 或在应用上架审核时声明需要 execmem 权限

### 方案 4：替代方案

如果完全无法开放 execmem，请提供：
- 官方的动态代码执行框架（类似 Android ART 的 JIT 模式）
- 或官方支持的 ARM 指令解释器接口

## 补充说明

- 同一设备在 HarmonyOS 6.1 上运行完全正常，升级 7.0 后才出现此问题
- Debug 签名和 Release 签名的表现相同（都被拒绝）
- 应用已在 AGC 注册并使用 DevEco Studio 自动签名
- 系统自身的 ArkCompiler JIT 在 7.0 上仍正常工作，说明限制仅针对第三方应用
- 应用使用 Unicorn Engine v2（基于 QEMU TCG），通过 NDK C/C++ 原生开发

## 相关文件

- 崩溃源码位置：`third_party/unicorn/qemu/accel/tcg/translate-all.c`，函数 `alloc_code_gen_buffer()`（line 1019）
- 项目 GitHub：https://github.com/Jiagu1218/vmrp-ohos
- 上游 Unicorn Engine：https://github.com/unicorn-engine/unicorn

---

## 更新（2026-08-01）：已查明官方授权通道 + TCI 保底方案已实施

### 官方授权通道（确认存在）

经查阅官方文档，HarmonyOS **API 18（5.1）**起执行策略变更，有明确的管控说明与申请通道：

- **变更说明**：[针对所有应用的变更 - 匿名内存执行权限管控策略变更说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/changelogs-for-all-apps-b031)
  > 为了维护生态的纯净，防止恶意应用向匿名内存注入指令，实现任意代码执行，以绕过代码签名管控……
- **申请指导**：[JSVM-API 申请JIT权限指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/jsvm-apply-jit-profile)
- **权限名**：`ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY`（受限 ACL 权限，`kernel.` 前缀表明是内核级可执行内存门控）
- **申请流程**：
  1. 在 [AppGallery Connect](https://developer.huawei.com/consumer/cn/doc/App/agc-help-internaltest-profile-0000002283269129) 提交受限权限申请，附带 JIT 使用场景说明
  2. 审批通过后，在 AGC「证书、APP ID 和 Profile」更新 Profile 证书（.p7b）
  3. 用新 Profile 重打包签名上架
- **FAQ 参考**：[未申请JIT权限导致应用卡死在启动页](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/faq-stability-16)

> ⚠️ 注意：未授权证书仅声明权限会导致**应用安装失败**；「安全盾模式」下系统会全局禁用 JIT（连授权应用也失效）。

### 已实施的保底方案：TCI 解释器移植

在等待 ACL 权限审批期间，我们已移植 **TCI（TCG Interpreter）**作为保底方案，使应用在**完全不触碰 `PROT_EXEC`** 的情况下恢复可用：

- **原理**：把 Unicorn 的 TCG backend 从「生成机器码到 RWX 内存」改为「序列化字节码到普通 RW 内存，再由 C 解释器循环执行」
- **改动文件**：`scripts/CMakeLists.txt`（补丁注入）+ `scripts/tci/`（3 个 TCI 源文件）+ `scripts/build_libvmpp_ohos.bat`（还原逻辑）
- **验证**：Mate 70 Pro / HarmonyOS 7.0.100 上应用启动不再崩溃，TCI 解释器正常运行（进程存活、渲染循环活跃）
- **代价**：比 JIT 慢 3-5×，但 MRP 是 2G 时代低速 ARM 代码，实测可接受
- **详细文档**：[docs/tci-interpreter-port.md](./tci-interpreter-port.md)

ACL 权限审批通过后，可移除 TCI 补丁块、恢复 `translate-all.c` 的 `PROT_EXEC` 分支切回 JIT 全速模式。

---

*提交时间：2026-08-01*
*联系方式：通过 GitHub Issues 或华为开发者论坛*
