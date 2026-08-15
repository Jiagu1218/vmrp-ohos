# Windows Vitest 支持进度

日期：2026-08-15

## 初始检测

- `package.json` 的 `vitest run test/e2e` 和 `vitest.config.ts` 本身没有 POSIX shell
  依赖，可以在 Windows 上运行。
- `pnpm-workspace.yaml` 缺少 `packages`，当前 pnpm 在加载 Vitest 前报
  `packages field missing or empty`。
- `src/e2e_control.c` 在 `_WIN32` 下编译为空实现，Windows 模拟器不会创建
  `SKYENGINE_E2E_SOCKET` 控制端点。
- `test/e2e/engine-e2e.ts` 固定使用 Unix socket 文件和 `stat().isSocket()`；Windows
  上 Node 的本地 IPC 使用命名管道，无法连接当前 C 端。
- Visual Studio 多配置构建的标准 Release 产物为
  `build/Release/skyengine.exe`，与测试辅助代码的 Linux 默认路径不一致。
- `.github/workflows/vitest.yml` 只在 Linux test job 安装 Node/pnpm 和运行 Vitest，
  Windows 没有 e2e 回归门禁。

结论：修改前不支持在 Windows 上运行 Vitest e2e；已有 Windows CMake 构建能力，
缺口集中在包管理入口、e2e IPC、可执行文件路径和 CI。

## 实施计划

1. 为 pnpm 工作区声明根包，使 `pnpm test:e2e` 能进入 Vitest。
2. 保留 Linux Unix socket，在 Windows 上实现同协议的本机命名管道。
3. 测试辅助代码按平台生成 IPC 端点、等待就绪并选择默认二进制路径。
4. 修正截图命令对带空格 Windows 临时目录的解析。
5. 在 Windows CI 中安装测试依赖并运行 Vitest。
6. 用 Windows MSVC Release 构建和代表性 Vitest 用例验证。

## 当前进度

- [x] 完成静态审查并确认不支持。
- [x] 声明 pnpm 根工作区。
- [x] 实现 Windows 命名管道控制端，Unix socket 协议保持不变。
- [x] 更新 TypeScript harness、Windows 默认 Release 路径与 CI。
- [x] 修正带空格/UTF-8 TEMP 路径的 SCREEN 命令和 PPM 文件打开方式。
- [x] `pnpm exec tsc --noEmit` 通过，Vitest 识别为 `win32-x64`。
- [x] Windows MSVC Release 构建 `skyengine` 与键盘单测成功，CTest 1/1 通过。
- [x] Windows `gxdzc/gxdzc-pixel.test.ts` 首次运行 1/1 通过（约 11.4 秒）。
- [x] `gghjt/game-start` 与 `dota/download-plugin` 共 4/4 用例并发通过。
- [x] `gxdzc` 在含空格及中文的 Windows TEMP 路径下分别通过。
- [x] 首轮全量为 37/38 文件、63/64 用例通过；唯一失败的 `gsha` 实际已发送
  590/590 字节，根因是 MSVC stdout 把 HTTP CRLF 捕获为 CRCRLF。日志断言规范化
  换行后，`gsha` 与公共 `stop()` 日志刷新定向回归 2/2 通过。
- [x] 最终 Windows `pnpm test:e2e`：38/38 文件、64/64 用例通过，耗时
  230.10 秒；没有重试失败、IPC 错误或临时目录清理错误。
- [x] 后续 CI 发现 `gtxzj/device-date` 的 6 个同步启动用例绕过 `VMRP_BIN`，
  因此错误查找本地 MSVC 默认路径 `build/Release/skyengine.exe`，而不是解压后的
  `build/skyengine.exe`。现已集中二进制解析逻辑，并新增 `VMRP_BIN` 优先级回归测试。
- [x] 设置 `VMRP_BIN` 后定向运行 `gtxzj/device-date.test.ts`，1/1 文件、10/10
  用例通过；`pnpm exec tsc --noEmit` 与 `git diff --check` 同时通过。
- [x] 按 CI 方式设置 `VMRP_BIN` 后再次运行 Windows 全量 `pnpm test:e2e`：
  38/38 文件、65/65 用例通过，耗时 227.87 秒。

## 最终结论

Windows 现在可以直接用 Visual Studio Release 产物运行 Vitest e2e。Windows
控制端使用本机命名管道，Unix 继续使用原有 Unix socket；两者共享相同命令协议，
所有 VM 调用仍由 SDL 主线程串行执行。CI 的 Windows test job 已启用同一全量套件。
