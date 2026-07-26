---
title: "GTLBD text disappearance debugging progress"
tags: ["gtlbd", "skyengine", "arm-ext", "disassembly", "text", "timer", "ppm", "allocator", "verified"]
created: 2026-07-26T08:09:54.684Z
updated: 2026-07-26T09:58:21.881Z
sources: []
links: []
category: debugging
confidence: medium
schemaVersion: 1
---

# GTLBD text disappearance debugging progress

# GTLBD text disappearance debugging progress

## Objective and constraints

Target command: `build/skyengine build/mythroad/gtlbd.mrp`. The initial Chinese prompt is visible, disappears after several idle seconds, and later interaction text is also missing. The repair must be generic: no application/package/address branch, no fallback behavior, no Xvfb, bounded tracing, commented production edits, PPM proof, and final cross-fixture compatibility.

## 2026-07-26 initial evidence

- `test/fixtures/gtlbd.mrp` and `test/e2e/gtlbd/text.test.ts` already exist as untracked user work; they must be preserved.
- The current test only waits for one initial cyan pixel, presses ENTER, and requires a later frame with more than seven colors. It does not yet prove idle persistence or later text persistence.
- `src/skyengine_args.c` has an unrelated/pre-existing DNS mapping edit and is not to be reverted.
- Main-loop timer events are already dispatched before edit-mode filtering (`src/main.c`), so the prior WBRW lost-one-shot-timer defect is historical context, not evidence of this root cause.
- Six bounded lanes are active: guest disassembly, dummy-driver PPM timeline, host rendering, timer/event routing, regression strengthening, and compatibility mapping.

## Current hypotheses (unproven)

1. A guest timer causes a background or layer present that overwrites text, while later text writes do not reach the visible foreground.
2. A host screen ownership/damage/clip state is incorrect after the timed transition.
3. A timer/event state defect stops or misroutes later guest UI work.

Evidence needed next: pre/post-idle PPM diffs with draw/timer generations, exact guest call sites from extracted ARM code, and bounded host API observation at those call boundaries.

---

## Update (2026-07-26T08:22:09.239Z)

## Objective and constraints

Target command: `build/skyengine build/mythroad/gtlbd.mrp`. The initial Chinese prompt is visible, disappears after several idle seconds, and later interaction text is also missing. The repair must be generic: no application/package/address branch, no fallback behavior, no Xvfb, bounded tracing, commented production edits, PPM proof, and final cross-fixture compatibility.

## 2026-07-26 initial state

- `test/fixtures/gtlbd.mrp` and `test/e2e/gtlbd/text.test.ts` are untracked user work and are preserved.
- `src/skyengine_args.c` has a pre-existing DNS mapping edit and must not be reverted.
- The old test oracle (`uniqueColorCount() > 7`) is invalid by itself: a correct interaction frame containing three white text lines has exactly seven colors. The test now uses region-level glyph counts and persistence comparisons.
- Main-loop timer events are already dispatched before edit-mode filtering, so the old WBRW edit-mode timer loss is not this defect.

## Exact reproduction and clean-workspace contrast

No Xvfb was used. All retained PPMs use SDL dummy and the existing E2E socket.

- Clean isolated workspace `/tmp/gtlbd-sequence-gGDoBQ`: home/prompt stays byte-identical for 6.9 seconds at SHA-256 `d57b4d7f2341324ecb6da67dbb372584070ccc0eff5f8ab93cc25081511da89e`; after ENTER, the three-line white interaction text is visible and remains byte-identical at `ca259911...`. This proves the old seven-color assertion was a false oracle, but does not disprove the user report.
- Exact executable-directory state `/tmp/gtlbd-exact-ALjSgA`, matching `build/skyengine build/mythroad/gtlbd.mrp`: idle seconds 0..3 are the correct prompt frame `d57b4d7f...`; at second 4 it changes to `e41925c7e24f852d8bae54f569b48592c2e1dc6240837e48872eb9f6e99b42b5` and the bottom prompt is gone; seconds 4..15 remain in that wrong state. After ENTER the frame becomes `97c6c14322c9bf6e62421a4ec09ac30da2cfc17e0023d34b9b8dd07d6de3b907`: black body with only soft-key icons and no interaction text, stable for another eight seconds. This is direct PPM proof of both reported symptoms.
- Both runs contain byte-identical extracted resources, `res.*`, and `785DBAD6/JMSW`; only four little-endian time-like words in `channel.sms` differ. The state directories therefore do not yet provide a semantic file-content explanation. Scheduling-sensitive behavior remains likely.

## Current leading cause

`src/main.c` assigns a generation to every `timerStart`, but the main loop currently invokes guest `timer()` for every queued SDL timer event without checking that event generation against `timerPendingGeneration`. `SDL_RemoveTimer` cannot retract an event already queued by the timer thread. If guest work rearms generation N+1 after N is queued but before N is consumed, stale N can consume the global RUNNING state and invoke the N+1 callback early; the real N+1 event then observes IDLE. This is a generic host timer identity hole, not an application-specific branch. It is not yet marked proven for GTLBD until the bounded runtime ordering and guest disassembly are complete.

## Competing causes

- A guest timer could legitimately clear the prompt and a screen owner/damage defect could hide only later text.
- Foreground-cover cache suppression is a generic render risk, but captures of the correct GTLBD path showed empty cover and accepted primary full-screen presents.
- Font/ROP/clip is down-ranked because correct glyphs are visible and stable in the successful schedule.

Next evidence: exact 3500ms guest timer call site and transition disassembly, queued/current generation ordering around the failing fourth second, and a deterministic isolated regression.

---

## Update (2026-07-26T08:51:51.939Z)

## 2026-07-26 framebuffer-boundary update

The deterministic isolated regression still fails with the fixed netpay fixture. Artifact `/tmp/skyengine-e2e-hrcUMp` captures bounded `SKYENGINE_ARM_EXT_TEXT_DIAG` evidence. Host glyph lookup is healthy: table[30] keeps returning nonzero 8x16/16x16 bitmaps with stable content hashes and the primary R9. After the service child is registered, table[120] repeatedly writes the same 111x65 background bitmap into the primary screen (`target=screen_addr`, `primary=1`), and the following accepted full-screen table[29] submits exactly that post-background framebuffer hash. The already-disassembled primary prompt branch and 0x23654C text function continue to execute, but the framebuffer no longer changes between background composition and present. This excludes SDL presentation, foreground rejection, wrong screen target, and missing host glyph data at this boundary. Next probe: bounded screen hashes at 0x23654C entry, internal 0x23E32C draw call, and return to determine which guest renderer/cache condition turns the text operation into a no-op after child registration.

---

## Update (2026-07-26T09:50:52.272Z)

## 2026-07-26 proven root cause and target fix

Bounded Unicorn header writes in /tmp/skyengine-e2e-RICX1U/stdout.log identified the first corruption: wrapper PC 0xE8263C repeatedly stored raw 4 into the registered skyfont image header at 0x26E474. Runtime base 0xE80000 maps this to cfunction.ext +0x263C, instruction str r5,[r4,#4], in the compact allocator split path, not table[44], cacheSync, framebuffer, or host memcpy. The wrapper disassembly at +0x20B4..+0x20D4 proves its malloc ABI: request len+4, eight-byte-align the raw allocation, store requested length at raw[0], and return raw+4. A register-level PC watch in /tmp/skyengine-e2e-IOuMmw/stdout.log captured the corrupting split exactly: free node r0=0x26E448, aligned request r2=0x28, new remainder header r4=0x26E470, remainder r5=4; the size store at r4+4 overwrote skyfont file_base[0].

The host compact-heap sanitizer had clipped registered storage at the returned user pointer. That manufactured a 0x2C free prefix ending at 0x26E474; the guest allocator split a 0x28 request from it and emitted the impossible four-byte tail. src/arm_ext/aex_mem.c now expands registered module images and ER_RW ranges to complete allocator cells: include the four-byte pre-user length header and round both boundaries to the allocator eight-byte granularity. This is ABI/data-structure based and contains no package, application, or runtime-address branch.

Target proof after the change: VMRP_E2E_KEEP_TMP=1 SKYENGINE_ARM_EXT_WATCH_HEADERS=1 pnpm vitest run test/e2e/gtlbd/text.test.ts passed. Artifact /tmp/skyengine-e2e-yeONPp has byte-identical prompt PPMs (d57b4d7f... initial and retained) and byte-identical interaction PPMs (ca259911... immediate and retained). Visual inspection shows 按任意键进入 after the idle interval and all three interaction text lines after another timer interval. No post-registration skyfont header write occurred. Temporary text/header diagnostics and the unrelated active-owner experiment were removed; final clean and compatibility verification remain.

---

## Update (2026-07-26T09:58:21.881Z)

## 2026-07-26 completion verification

The diagnostic-free target rerun passed in 13.79 seconds: VMRP_E2E_KEEP_TMP=1 pnpm vitest run test/e2e/gtlbd/text.test.ts. Clean artifact /tmp/skyengine-e2e-C2ECpU retained four PPM checkpoints. Initial and retained prompt frames are byte-identical at SHA-256 d57b4d7f2341324ecb6da67dbb372584070ccc0eff5f8ab93cc25081511da89e. Immediate and retained interaction frames are byte-identical at SHA-256 ca259911c3e4fad05da8000c877b2760617fb9a772b2b1280d7ef6c73c6954e1. The test asserts glyph counts in bounded regions as well as zero pixel differences across both idle intervals.

Final validation: CMake rebuild passed; pnpm exec tsc --noEmit passed; the full compatibility suite pnpm vitest run test/e2e --reporter=dot passed 33 files and 56 tests in 272.99 seconds. This includes direct compact allocators, module reuse, nested plugin staging, golden frames, font flows, memory-size variants, download/install/cancel paths, and GTLBD itself. Two independent reviews found no code defects. Temporary header/text diagnostics were removed. The shipped change surface is src/arm_ext/aex_mem.c plus test/e2e/gtlbd/text.test.ts and the fixed GTLBD fixture.
