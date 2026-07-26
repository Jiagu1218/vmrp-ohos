---
title: "gjxwsmn netpay plugin update progress"
tags: ["gjxwsmn", "netpay", "payment", "dns-map", "reverse-engineering", "e2e", "completion-audit"]
created: 2026-07-25T07:31:12.008Z
updated: 2026-07-25T07:41:03.446Z
sources: ["src/network.c", "tool/pay-server/skymobi-pay-server.go", "test/e2e/gjxwsmn/temp.test.ts", "vitest.config.ts"]
links: []
category: debugging
confidence: high
schemaVersion: 1
---

# gjxwsmn netpay plugin update progress

## 2026-07-25 baseline

Target command:

```bash
VMRP_E2E_KEEP_TMP=1 pnpm vitest run test/e2e/gjxwsmn/temp.test.ts --retry=0 --reporter=verbose
```

Result: failed at the final update-screen pixel check. Artifact directory:
`/tmp/skyengine-e2e-Su0YKW`; workspace:
`/tmp/skyengine-ws-lubmfv`.

Observed PPM evidence:

- `pay-1.ppm`: 240x320, 257 colors, `(103,161)=[104,104,224]`.
- `update-1.1.ppm`: 240x320, 47 colors, `(103,161)=[248,220,144]`.
- Expected final pixel is `[48,52,16]`, so the plugin-update prompt did not
  appear.

Observed plugin file state after failure:

- Runtime `/tmp/skyengine-ws-lubmfv/mythroad/plugins/netpay.mrp` is byte-for-byte
  `test/fixtures/plugins/netpay.mrp`, SHA-256
  `6f6d7f07d9751860bd77f76e4b844bf60332e6a36af1966ccb86eecdff3cfd4c`,
  MRP header appid `480010`, version `386`.
- Update target `test/fixtures/plugins/netpay-original.mrp` is SHA-256
  `fa8f64372d812ff718df3f2ccb62402c9142a5042c5df88d52c851ce4a5bb812`,
  MRP header appid `480010`, version `370`.

Observed network/log state:

- The failed run only logged two `POST /payOneAsTlv` requests to
  `rop.skymobiapp.com`, remapped to the local test server.
- No `simpleDownload`, `mr_remove`, `mr_rename`, or generated `vld/` update file
  appeared in the preserved stdout/workspace.

Current inference:

- The missing behavior is earlier than file replacement: the runtime never
  enters a plugin update/download path in this baseline.
- The version gate should be investigated against the MRP header version field
  at offset 72/196. The current installed fixture is version `386`; the expected
  replacement fixture is version `370`.

## 2026-07-25 resolution

The local `/payOneAsTlv` response now reports a real plugin update when the REG
request lists appid `480010` at installed version `386`. The minimal response is:

- type `100`: status `203` (plugin update available)
- type `200`: action `12` (continue registration)
- type `111`: one update item
- nested type `113`: simpleDownload resource id `480010`
- nested type `114`: resource variant `1`
- nested type `115`: plugin appid `480010`
- nested type `116`: server version `387`
- nested type `117`: interactive update mode `0`

The critical field is nested TLV `117`. Runtime tracing and disassembly showed
that `netpay+0x9e7a` copies update-item offset `+16` (TLV `117`) into netpay
state offset `+52`. The progress renderer at `netpay+0xa120` checks that state
field and returns without drawing when it is nonzero. Returning `117=1` starts
a silent update and suppresses every progress frame. Returning `117=0` displays
the plugin's update confirmation; pressing the left soft key starts verdload
while leaving the renderer enabled.

The extracted v386 `netpay.ext` used for this analysis has SHA-256
`7b171a57306f42156429ae83267f262e99574fb1e71ce9cc00113601f2036a36`.
`arm-none-eabi-objdump -D -b binary -m arm -M force-thumb` gives the decisive
instructions (module-relative offsets):

```text
9e6e  ldr  r1, [r3, #52]
9e70  cmp  r1, #0
9e72  bne  9e7c
9e74  ldr  r1, [r2, #24]   ; update-item array
9e76  add  r1, lr           ; selected item, 24-byte stride
9e78  ldr  r1, [r1, #16]   ; parsed TLV 117
9e7a  str  r1, [r3, #52]   ; netpay render-suppression state

8114  ...                   ; verdload callback
8122  cmp  r4, #2           ; progress event
8126  mov  r1, r6           ; total bytes
8128  mov  r0, r7           ; downloaded bytes
812a  bl   a120              ; render progress

a120  push {r4-r7, lr}
a124  ldr  r0, [pc, #236]
a128  add  r0, r9
a12a  ldr  r0, [r0, #52]
a12e  cmp  r0, #0
a130  bne  a20e              ; skip renderer when TLV 117 was nonzero
```

The download remains entirely real. `spd.skymobiapp.com` is DNS-mapped directly
to `159.75.119.124`, and verdload sends `POST /simpleDownload` to port `6009`.
The production response is read in 2 KiB chunks, its envelope is stripped by
verdload, and the resulting file replaces `plugins/netpay.mrp` byte-for-byte.

The E2E test now captures new draw frames immediately with `WAIT_DRAW` followed
by `SCREEN_DRAW`; it does not wait until installation finishes because the draw
history is bounded. A preserved verification run captured draws `102..183`:

- black wait frame
- initial registration prompt
- update confirmation prompt
- download frames from `0/0K` through `156/156K`
- final payment result frame

The progress assertion checks the plugin's actual bar at row `160`: white border,
black unfilled area, and cyan fill growing monotonically from `0` to `104` pixels
across multiple distinct values. Full-screen differences, synthetic percentages,
and synthetic completion are not accepted. The installed SHA-256 is
`fa8f64372d812ff718df3f2ccb62402c9142a5042c5df88d52c851ce4a5bb812`,
identical to `test/fixtures/plugins/netpay-original.mrp`.

## 2026-07-25 Go pay-server verification

`tool/pay-server/skymobi-pay-server.go` now derives the same update response from the REG
request's nested plugin report. The server only advertises version `387` when
appid `480010` reports installed version `386`; its nested type `117` remains
zero so the confirmation and progress renderer stay visible. The obsolete
`RESP_TLV_FILE` response override was removed. `/simpleDownload` remains outside
the local server and is reached through the direct DNS map to `159.75.119.124`.

The E2E test was run against the Go process itself on port `18088`, rather than
the test's in-process response implementation. It passed and preserved artifacts
at `/tmp/skyengine-e2e-n88riI` with workspace `/tmp/skyengine-ws-GTTeMX`.
Inspection found 79 saved update frames, including 78 valid progress frames with
78 distinct fill widths, monotonically increasing from `0` to `104`. The saved
confirmation, mid-download, and completed views are also available as:

- `/tmp/gjxwsmn-go-pay-update-confirmation.png`
- `/tmp/gjxwsmn-go-pay-update-mid.png`
- `/tmp/gjxwsmn-go-pay-update-complete.png`

The runtime's installed `mythroad/plugins/netpay.mrp` SHA-256 is
`fa8f64372d812ff718df3f2ccb62402c9142a5042c5df88d52c851ce4a5bb812`,
again byte-for-byte identical to `test/fixtures/plugins/netpay-original.mrp`.

## 2026-07-25 item-payment reproduction

The earlier Go-server run only proved the plugin-update portion of the test. It
did not continue through the game's item purchase, so it was not evidence that
item payment succeeded.

A fresh run against the externally started Go server on port `8088` preserved
artifacts in `/tmp/skyengine-e2e-HABeFk` and the workspace in
`/tmp/skyengine-ws-zBDHcD`. The plugin update still completed, with draws
`102..183` captured and the installed plugin matching the update fixture. The
later item-payment assertion failed after about 57 seconds.

Direct PPM inspection of `pay-end-1.0.ppm` shows the actual message:

```text
收费提示
由于网络问题，无法获取信息，请稍后重试！
```

The focused runtime log identifies a concrete connection failure after the
updated plugin switches from CMWAP to CMNET:

```text
my_getHostByName('rop.skymobiapp.com', NULL)
dns map: rop.skymobiapp.com -> 127.0.0.1:8088
my_connect(fd:12, '127.0.0.1', 80)
my_connect(0x7F000001) fail
my_getSocketState(6): -1

my_connect(fd:12, '127.0.0.1', 6009)
my_connect(0x7F000001) fail
my_getSocketState(7): -1
```

Evidence: the DNS lookup applies both the mapped address and configured port in
its diagnostic output, but the guest's later explicit `my_connect` call receives
only the resolved IPv4 value and therefore still uses its original port. The
current `applyDnsMappedEndpointPort` call only covers the CMWAP deferred-connect
path inside `my_send`; it cannot affect this CMNET resolve-then-connect path.

Current inference, pending the local netpay disassembly and a fixed rerun: the
first item-payment failure is caused by losing the DNS endpoint port override
between `my_getHostByName` and the explicit asynchronous `my_connect`. The exact
successful item-payment response remains unknown until the request reaches the
Go server, so no server-response assumption should be added yet.

## 2026-07-25 mapped-endpoint verification

The DNS endpoint fix was rebuilt and exercised against the independently
started `tool/pay-server/skymobi-pay-server.go` process. The run retained
artifacts in `/tmp/skyengine-e2e-dGBUM6` and its workspace in
`/tmp/skyengine-ws-rh0ZcI`.

Both network modes reached the configured endpoint. In particular, the v370
plugin's asynchronous CMNET path resolved a synthetic route token and connected
to the mapped host endpoint instead of the request's original ports:

```text
dns_route hit: token=0xF0000020 -> ip=0x7F000001 port=8088
my_connect(fd:12, '127.0.0.1', 8088)
my_connect(0x7F000001) suc
```

The original HTTP routing bytes were not rewritten: the Go server received
requests with `X-Online-Host: rop.skymobiapp.com:80` and later
`X-Online-Host: rop.skymobiapp.com:6009`. The installed netpay SHA-256 was still
`fa8f64372d812ff718df3f2ccb62402c9142a5042c5df88d52c851ce4a5bb812`,
identical to `test/fixtures/plugins/netpay-original.mrp`.

This run exposed the next, separate protocol gap. The server received four
exact TLV requests with `0x0452 = "PROP"`, `0x03f1 = "000000011"`, a changing
four-byte transaction in `0x045b`, and retry state `0x03fe` changing from `2`
to `1`. Its current non-`REG` response is only:

```text
0x03f1 = "000000006"
0x044f = 0
```

That 29-byte non-entitling response is not a successful item-payment contract;
the test still ends on the network-error dialog. A successful `PROP` response
must therefore be derived from the v370 netpay response parser before changing
the Go server. HTTP 200 alone is already proven insufficient.

## 2026-07-25 v370 PROP completion

Disassembly of the updated v370 `netpay.ext` supplied the missing response
contract. Its common response parser at module offset `+0x4d2c` reads TLVs
`101`, `100`, and `200`. A big-endian value `100=200` passes the status gate,
and the one-byte action `200=12` reaches the normal completion branch at
`+0x1f590`. TLV `101` is parsed, but no comparison or later use of its parsed
destination was found in the v370 consumer paths. The server therefore echoes
the request's four-byte `0x045b` transaction in TLV `101` as a conservative
choice, not as a claimed universal protocol requirement.

The standalone Go server now returns this 33-byte body for both ordinary `REG`
continuation and `PROP` completion:

```text
101 = request TLV 0x045b transaction
100 = u32be(200)
200 = byte 12
```

For example, transaction `00008f97` produces:

```text
000000650000000400008f97
0000006400000004000000c8
000000c8000000010c
```

Unknown stages and requests without an exact four-byte transaction retain the
old non-entitling response. There is no generic fallback-success path. No
authentic production `PROP` success capture was found in repository history,
editor or shell history, retained proxy captures, or response-shaped temporary
artifacts, so this response is documented as a behaviorally validated v370
equivalent rather than an original Skymobi capture.

The target test passed repeatedly against the independently started Go server.
The strengthened run retained artifacts at `/tmp/skyengine-e2e-pLWgGx` and its
workspace at `/tmp/skyengine-ws-7OICJK`. The final `pay-end-1.0.ppm` returned to
the storefront and showed the first item as enabled, with exact pixels
`(133,55)=[232,164,72]` and `(137,55)=[104,36,0]`; the failed network dialog had
`[104,104,224]` at both positions. The runtime also created the nonempty
application entitlement file `mythroad/gjxwsmn/combo.sid`. These assertions
distinguish accepted payment from an HTTP-only or visual false positive.

## 2026-07-25 DNS route-token design and compatibility

Port-bearing DNS mappings now return a synthetic guest IPv4 token backed by an
immutable `{resolvedIp, port, generation}` route. `my_connect` translates only
an exact active token, so unrelated addresses in the reserved `240/4` range and
stale tokens keep ordinary IPv4 behavior. Identical endpoints reuse a token;
the table is bounded at 256 routes and is invalidated on DNS reconfiguration or
`my_closeNetwork()`.

This intentionally extends the guest-facing DNS ABI: a mapped lookup with an
explicit port receives an opaque route token rather than the resolved address.
The benefit is that the otherwise separate `my_getHostByName` and `my_connect`
calls preserve the configured endpoint atomically. The tradeoff is that guest
code must treat DNS results as connection inputs instead of inspecting mapped
addresses as literal IPv4 values. Unmapped and portless lookups are unchanged,
and route-capacity exhaustion fails the lookup instead of silently connecting
to the request's original port.

A focused compatibility matrix covering 11 existing E2E files completed with
all 21 tests passing in 232.79 seconds. It included browser/plugin downloads,
paid flows, startup and rendering cases, a 4 MiB boot, and the intentionally
slow payment-timeout path. This exercises both mapped and ordinary networking
outside `gjxwsmn` and found no regression from the token translation.

The repository's complete default `pnpm test:e2e` suite also passed: 31 test
files and 54 tests in 272.93 seconds. The default suite intentionally excludes
`test/e2e/gjxwsmn/temp.test.ts`; that target was verified separately against the
external Go pay server as described above.

---

## Update (2026-07-25T07:41:03.446Z)

### 2026-07-25 completion audit

An independent verifier reran the focused test against the already-running external Go server: `VMRP_E2E_KEEP_TMP=1 pnpm vitest run test/e2e/gjxwsmn/temp.test.ts --retry=0 --reporter=verbose` passed one test in 47.59 seconds. Fresh artifacts are `/tmp/skyengine-e2e-Gh2jLg` and `/tmp/skyengine-ws-5RX6B0`. The P6 240x320 payment frame changed both sampled positions from `[104,104,224]` before completion to `(133,55)=[232,164,72]` and `(137,55)=[104,36,0]` afterward. The new 113-byte `combo.sid` has SHA-256 `a35e9f1689735a2f97d460468e78da64b7a2dc8d475d26418e218a408ad65460`; the installed 156211-byte netpay MRP and fixture both hash to `fa8f64372d812ff718df3f2ccb62402c9142a5042c5df88d52c851ce4a5bb812`. Runtime stdout proves connections to `127.0.0.1:8088`, three `/payOneAsTlv` requests, direct `159.75.119.124` plugin download, and `/simpleDownload`.

The verifier then reran `pnpm test:e2e`: all 31 files and 54 tests passed in 274.48 seconds. A separate final code review found no production-code blocker and withdrew its initial harness concerns after confirming that `temp.test.ts` is intentionally excluded from default Vitest/CI and that the user-required external-server prerequisite is explicit. The moduleless Go utility passes `go test skymobi-pay-server.go skymobi-pay-server_test.go` from `tool/pay-server`. No Xvfb, embedded test server, fallback success, or application-specific runtime branch is used.
