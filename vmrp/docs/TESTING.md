# VMRP Testing

## Test Runner

VMRP now keeps the automated test entrypoint in Vitest only. CMake only builds
emulator/library targets; build `skyengine`, then run the TypeScript e2e tests with
pnpm.

```bash
cmake --build build --target skyengine
pnpm test:e2e
```

On Windows with the Visual Studio generator, build the configuration used by the
harness before running the same Vitest command:

```powershell
cmake -S . -B build -A x64
cmake --build build --config Release --target skyengine
pnpm test:e2e
```

The Windows default is `build/Release/skyengine.exe`. Set `VMRP_BIN` when using a
different configuration or output directory, for example
`$env:VMRP_BIN = 'build/Debug/skyengine.exe'`.

To run a focused scenario:

```bash
pnpm vitest run test/e2e/opbzqe/game-prepare.test.ts
```

## E2E Harness

The Vitest harness starts the platform's default SkyEngine binary with
`SKYENGINE_E2E_SOCKET`. It uses a Unix domain socket on Unix and a local named pipe
on Windows. Commands are marshalled onto SDL's main thread before they touch input
handling or screenshot capture.

Supported commands:

```text
CLICK x y
KEY name
SCREEN path
DRAW_COUNT
WAIT_DRAW previous timeout_ms
QUIT
```

The harness sets `SDL_AUDIODRIVER=dummy` by default and does not require
`xvfb`.

Useful environment overrides:

| Variable | Purpose |
| --- | --- |
| `VMRP_BIN` | Path to the SkyEngine executable; defaults to `build/skyengine` on Unix and `build/Release/skyengine.exe` on Windows. |
| `SKYENGINE_WORK_DIR` | Runtime working directory, defaults to repository root. |
| `VMRP_TIMEOUT_MS` | Local IPC startup and command timeout. |

## Visual Assertions

Screenshots are dumped as PPM files by the e2e `SCREEN` command and read
directly in TypeScript.  Tests assert exact RGB pixels for stable UI states and
menu transitions.

Current e2e examples live under `test/e2e/`, including:

- `test/e2e/opbzqe/game-prepare.test.ts`
- `test/e2e/dota/download-plugin.test.ts`
- `test/e2e/gxdzc-pixel.test.ts`
- `test/e2e/gghjt/*.test.ts`
