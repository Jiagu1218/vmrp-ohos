---
title: "AQCW payOne local payment progress"
tags: ["aqcw", "payment", "payOne", "reverse-engineering", "e2e", "ppm"]
created: 2026-08-14T11:00:23.830Z
updated: 2026-08-14T11:59:06.415Z
sources: []
links: ["aqcw-payone-response-contract.md"]
category: debugging
confidence: high
schemaVersion: 1
---

# AQCW payOne local payment progress

## 2026-08-14 baseline and routing evidence

Target command:

```bash
pnpm vitest run test/e2e/aqcw/download-plugin.test.ts
```

Current worktree facts:

- `test/e2e/aqcw/download-plugin.test.ts` and `test/fixtures/aqcw_1014.mrp` are user-owned untracked files.
- The test starts `SkyEngineE2e` with only `workDir`, so it uses the global default `rop.skymobiapp.com->159.75.119.124` and never reaches the local Go server.
- A port-bearing map is required: `rop.skymobiapp.com->127.0.0.1:8088`. Portless localhost would preserve the guest's original 80/6009 port.
- The Go server accepts every URL through one handler but always parses the body as exact TLV and emits the `/payOneAsTlv` response contract. It therefore does not implement the distinct `/payOne` protocol.

Baseline run with the unmodified test reported Vitest pass in 5.9 seconds, but this is a false positive. Preserved artifacts:

- engine artifacts: `/tmp/skyengine-e2e-3NfzYP`
- workspace: `/tmp/skyengine-ws-MMz66D`
- `pay.ppm`: 240x320, SHA-256 `7dfb67332f38b67374f632d8f4e34254f92768f3dc9a5ed3e8e79660c28944b0`
- the PPM visibly says `提示信息 / 正在获取更多信息,请稍候。`
- the test only checks that pixel `(160,58)` is not a background color, so this waiting page satisfies the current assertion without proving payment success.
- the independently started `PORT=8088 go run tools/pay-server/skymobi-pay-server.go` received no request.

## Static package and disassembly boundary

The AQCW fixture contains its own `smsend.mrp` entry. After structured MRP extraction:

- outer `smsend.mrp` SHA-256: `ca56e90feb1d9cfdead19368da7461cdf056a3e7b464db9e42b130be5ff9c38f`
- decoded `smsend.ext` SHA-256: `bb08b2786b8540ba0074d18141bab9ed0f2e7d0621cc60d3d0fb552da34e9109`
- `smsend.ext` contains `rop.skymobiapp.com:6009` at file offset `0xb3e0`, `payOne` at `0xb3f8`, `Content-Type: application/x-www-form-urlencoded` at `0xb47c`, and form-field strings around `0xb940..0xbaf8`.
- The runtime's separate `plugins/netpay.mrp` is v386 (SHA-256 `6f6d7f...`); its decoded `netpay.ext` only contains `payOneAsTlv`. That existing TLV protocol cannot be projected onto the AQCW `/payOne` parser.

## 2026-08-14 verified fix

The first diagnostic runs mapped `rop.skymobiapp.com` to `127.0.0.1:8088`. A live run captured `POST /payOne` with `application/x-www-form-urlencoded` and a dynamic decimal `msgid`; the server echoes that ID in a path-specific binary response. The existing `/payOneAsTlv` handler remains separate and unchanged.

The final response is a 33-byte TLV stream. See [[aqcw-payone-response-contract]] for the disassembly evidence and exact layout. The decisive watched run used request `msgid=5708` and showed:

- parser return 0 at `smsend.ext+0x338a`;
- status 200 at `+0x3392`;
- current and echoed IDs both `0x164c` at `+0x3398..+0x339e`;
- action 1 at `+0x33d0`;
- direct completion at `+0x865c`, followed by state 7 at `+0x9f90`;
- no visit to the failure target `+0x85f0`.

Visual verification used real 240x320 PPM captures without Xvfb:

- waiting screen SHA-256: `7dfb67332f38b67374f632d8f4e34254f92768f3dc9a5ed3e8e79660c28944b0`;
- success screen SHA-256: `69f5fe59c381ef09ac0ffc2d9415c3f81d004e75205a6347c13a115cd32ce9b3`;
- the success frame visibly says `恭喜您支付成功!` and asks the user to return to enjoy the content.

The original pixel inequality remained false on a genuine success page because `(160,58)` is dark green background in both states. The test now checks two exact white pixels from the first and last success-message lines, both dark background on the waiting page. The focused test passes without debug watches in 6.9 seconds.

## Deterministic lifecycle and compatibility verification

Because AQCW is part of the default E2E suite, leaving an external server prerequisite would fail on clean CI and could collide with another process on port 8088. The final test therefore:

- builds `tools/pay-server/skymobi-pay-server.go` into a dedicated temporary directory;
- starts that binary with `PORT=0` and waits for the post-`Listen` log containing the kernel-selected port;
- maps AQCW to that exact port;
- terminates the owned process and removes its binary in `afterEach`.

The Go server logs `listener.Addr()` only after a successful bind, making `PORT=0` readiness generic and race-free. With no external listener on 8088, the focused AQCW command passed and left no pay-server process or temporary build directory.

Compatibility results:

- Go handler/body tests passed;
- focused AQCW payment passed;
- `gjxwsmn/temp.test.ts` passed, exercising the preserved `/payOneAsTlv` REG/update/PROP flow;
- OP6120's two offline boot cases passed;
- all five GGHJT plugin/payment-timeout cases passed, confirming its port-80 route remains isolated;
- the final self-contained `pnpm test:e2e` run passed all 37 files and 64 tests in 217.09 seconds under eight-way file concurrency.

The timing-sensitive GGHJT timeout/menu case failed once in an earlier targeted run and used one configured retry in the final suite. It passed on isolated rerun and in both complete suites; no compatibility code was changed for it.
