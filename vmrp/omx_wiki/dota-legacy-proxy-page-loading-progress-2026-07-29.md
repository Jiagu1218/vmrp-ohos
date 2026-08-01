---
title: "DOTA legacy proxy page loading progress 2026-07-29"
tags: ["dota", "wbrw", "proxy", "proxy2", "upstream-error", "e2e", "sky-format", "protocol"]
created: 2026-07-29T11:02:03.700Z
updated: 2026-07-29T11:52:18.734Z
sources: ["/home/msojocs/github/skyengine-tools/proxy2/server.go", "/home/msojocs/github/skyengine-tools/proxy2/server_test.go", "/tmp/skyengine-e2e-4b8H0g/url-opened.ppm", "/tmp/brwcore-OGPvew.thumb.dis", "/home/msojocs/github/vmrp/test/e2e/dota/temp.test.ts", "/tmp/skyengine-e2e-n0v72M/url-opened.ppm"]
links: []
category: session-log
confidence: medium
schemaVersion: 1
---

# DOTA legacy proxy page loading progress 2026-07-29

# DOTA legacy proxy page loading progress 2026-07-29

## Objective

Run `test/e2e/dota/temp.test.ts`, preserve the loaded browser frame, and make the unavailable source URL render a valid SKY error page containing `Upstream error`.

## Initial evidence (11:01 CST)

- The repro maps both `proxy.51mrp.com` and `proxy2.51mrp.com` to `127.0.0.1`, but DOTA/WBRW uses the legacy `proxy.51mrp.com` host.
- The live Nginx config accepts both hosts and forwards `/$endpoint` to `http://host.docker.internal:8089/mrp/$host/$endpoint`.
- The Air-managed `skyengine-tools` server is healthy on `0.0.0.0:8089`.
- `GET /sta` through Nginx returns `retcode=0` for Host `proxy2.51mrp.com`, while Host `proxy.51mrp.com` returns HTTP 404.
- `proxy2.Service.Register` currently registers only `/mrp/proxy2.51mrp.com/{sta,page2,res,mrp,image}`.
- `proxy2.Service.writePageError` already builds the desired valid SKY page titled `Upstream error` when an upstream fetch fails.

## Current inference

High confidence: the legacy host is reaching the local service, but its prefixed route is rejected before packet parsing or upstream fetch. The original repro run and guest stdout/stderr are still required before treating this as the verified root cause.

## Preservation

The pre-existing user edit in `docs/prompt.md` is unrelated implementation input and must not be reverted.

---

## Update (2026-07-29T11:13:35.213Z)

# DOTA legacy proxy page loading progress 2026-07-29

## Objective

Run `test/e2e/dota/temp.test.ts`, preserve the loaded browser frame, and make the unavailable source URL render a valid SKY error page containing `Upstream error`.

## Baseline evidence

- The repro maps both proxy hosts to `127.0.0.1`, but the downloaded DOTA browser uses `proxy.51mrp.com`.
- Guest stdout showed a successful TCP connection to `127.0.0.1:80`, followed by `POST /page2`, Host `proxy.51mrp.com`, and HTTP 404.
- Baseline artifact `/tmp/skyengine-e2e-pohR3v/url-opened.ppm` (SHA-256 `41b3221396a03964da30031b3bc18e4e1fa9375459046ef12485ffb58554651c`) renders `网络连接错误74`.
- The live Nginx config rewrites the request to `/mrp/proxy.51mrp.com/page2`, while the Go service initially registered only `/mrp/proxy2.51mrp.com/page2`.

## First implementation and verification

- Added the legacy host prefix to the Go service route registration and direct handler normalization.
- Aligned the checked-in Nginx sample with Host `proxy.51mrp.com` and Air port `8089`.
- Added a deterministic Go test that invokes the legacy page route and verifies the proxy packet contains `Upstream error`.
- `go test ./...` passed; after Air reload, legacy `GET /sta` changed from 404 to 200 `retcode=0`.

## Second runtime finding

Routing alone is insufficient:

- Post-route artifact `/tmp/skyengine-e2e-i5rKRH/url-opened.ppm` renders `获取页面错误7`.
- Guest stdout received HTTP 200 with 1096 bytes. Its cache file `/tmp/skyengine-ws-S5tfWc/mythroad/brw/http/cache3/32539.dat` is the 923-byte generated SKY payload and contains the target URL, title `Upstream error`, and UCS-2 body `Upstream error: HTTP 502 Bad Gateway`.
- This proves packet routing, envelope status/tag 33, and caching succeeded; rejection occurs while the old browser core parses the SKY document.
- The rejected page includes the current Go generator's `0x10` style/glyph prelude before the `0x0f` display records. Earlier repository evidence documents a compact programmatic format whose body begins directly with `0x0f`, and that format rendered in WBRW.
- A separate post-route run `/tmp/skyengine-e2e-ikbop7/url-opened.ppm` captured the intermediate `数据请求...` frame because the request outlived the repro's fixed 5-second delay. The script's green exit is not success evidence.

## Current hypothesis

High confidence: the old `proxy.51mrp.com` browser component requires the compact SKY dialect, while current `proxy2.51mrp.com` clients retain the style-prefixed dialect. Next discriminating implementation is host-prefix-selected compact generation, followed by a fresh screenshot.

## Environment and preservation

- Air listens on `0.0.0.0:8089`; Docker Nginx owns port 80 and currently forwards both proxy hosts to 8089.
- The pre-existing user edit in `docs/prompt.md` and concurrent `vitest.config.ts` edit must not be reverted.

---

## Update (2026-07-29T11:43:37.844Z)

## Objective

Run `test/e2e/dota/temp.test.ts`, preserve the loaded browser frame, and make the unavailable source URL render a valid SKY page containing `Upstream error`.

## Baseline and routing fix

- DOTA downloads the legacy browser and sends `POST /page2` with Host `proxy.51mrp.com`.
- Nginx rewrites that request to `/mrp/proxy.51mrp.com/page2`; the Go service initially registered only `/mrp/proxy2.51mrp.com/page2`.
- Baseline screenshot `/tmp/skyengine-e2e-pohR3v/url-opened.ppm` showed `网络连接错误74`, and guest stdout proved the response was HTTP 404.
- `skyengine-tools` now registers both current and legacy prefixes for all five endpoints. Its sample Nginx config accepts both hosts and targets the Air port `8089`; README documents both route sets and the actual port.
- The live externally mounted Nginx config already had the correct hosts and port, so it was not edited.

## Error 7 root cause

After the route fix, HTTP 200 and the complete 923-byte SKY payload were cached, but the screenshot showed `获取页面错误7`. Several SKY-content hypotheses were discriminated and rejected:

- Removing the style prelude produced a complete 250-byte cache and still showed error 7.
- A hand-built 207-byte legacy/unflagged page was completely received and cached and still showed error 7.
- A 6035-byte historical page was inconclusive because the fixed capture window received only the first 2048 bytes.
- Historical files do prove two SKY record dialects exist, but that fact does not explain this error.

Direct `brwcore.ext` disassembly established the actual ordering:

- The response parser reads field 7 as big-endian u16 and requires `0x0641`.
- A mismatch sets browser error 7 before the SKY payload is fed to the document parser.
- A separate lower-level gate requires packet status 200 and field 33 value 3; failure there produces error 74.
- Evidence: `/tmp/brwcore-OGPvew.thumb.dis` around lines 13177, 13268, 13320, 13328, and 13498.

Therefore `获取页面错误7` was an envelope metadata failure, not a malformed SKY document.

## Final implementation

- Added a shared page-field helper in `proxy2/server.go`.
- Every successful `/page2` response carrying SKY, including generated HTML and generated upstream-error pages, now includes `tag 7 = BE16(0x0641)` and the existing `tag 33 = 3`.
- Added unit assertions for both the ordinary generated page and the legacy-prefix HTTP 502 error-page path.
- Removed both temporary `/tmp/proxy2-page-debug.sky` source hooks and deleted the diagnostic fixture.
- The compact generator experiment was fully reverted; current `html2sky` behavior remains unchanged.

## Final verification

- `go test ./...` passed in `/home/msojocs/github/skyengine-tools`.
- No-retry repro command passed in 37.77 seconds.
- Retained artifact directory: `/tmp/skyengine-e2e-4b8H0g`.
- Retained workspace: `/tmp/skyengine-ws-skMzaa`.
- Guest network log shows `POST /page2`, Host `proxy.51mrp.com`, HTTP 200, and one 1102-byte receive.
- Cache `mythroad/brw/http/cache3/37160.sky` is 923 bytes and contains `Upstream error`.
- Final PPM SHA-256: `4f269647ef012227016aa750643ed4a9ce7931c9fe42897a9fde0d045dc73dbc`.
- Manual inspection of `/tmp/skyengine-e2e-4b8H0g/url-opened.png` shows title `Upstream error` and body `Upstream error: HTTP 502 Bad Gateway`; it does not show error 7, error 74, or the loading screen.

## Preservation

The repro script itself was not converted into an assertion-based test. Pre-existing edits in `docs/prompt.md` and concurrent `vitest.config.ts` were preserved.

---

## Update (2026-07-29T11:52:18.734Z)

## Final timing stabilization

The page fix itself was already verified, but the reproduction script originally captured after a fixed 5 seconds. The dead upstream sometimes returns HTTP 502 immediately and sometimes only fails at the Go client 15-second timeout, so a 5-second capture could still preserve the intermediate `数据请求...` screen while the protocol path was healthy.

Because this file is explicitly a screenshot reproduction script rather than an assertion-based test, its final wait was extended from 5 to 20 seconds. No screenshot assertion was added.

## Final retained evidence

- Final no-retry run passed in 51.62 seconds.
- Artifact directory: `/tmp/skyengine-e2e-n0v72M`.
- Workspace: `/tmp/skyengine-ws-6Zqi3k`.
- Guest network log shows `POST /page2`, Host `proxy.51mrp.com`, one 1102-byte response receive, and HTTP 200.
- Cache `mythroad/brw/http/cache3/31260.sky` is 923 bytes and contains `Upstream error`.
- Final PPM SHA-256: `6b1ec5336d116bec65d9520be691c3581e3582e5e06474b893ca9eee0da88e36`.
- Manual inspection of `/tmp/skyengine-e2e-n0v72M/url-opened.png` shows title `Upstream error` and body `Upstream error: HTTP 502 Bad Gateway`.
- The final screenshot does not show `获取页面错误7`, `网络连接错误74`, or `数据请求...`.
- A second independent retained success from the runtime investigation is `/tmp/skyengine-e2e-VdamSa/url-opened.png`, confirming the result is not unique to one run.
