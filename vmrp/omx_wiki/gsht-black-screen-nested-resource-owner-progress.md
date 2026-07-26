---
title: "GSHT black screen nested resource owner progress"
tags: ["gsht", "arm-ext", "table125", "resource-owner", "disassembly", "black-screen", "ppm"]
created: 2026-07-25T10:27:32.935Z
updated: 2026-07-25T11:15:01.000Z
sources: ["src/arm_ext_executor.c", "src/arm_ext/aex_table.c", "build/mythroad/311019_1015_gsht.mrp"]
links: []
category: debugging
confidence: high
schemaVersion: 1
---

# GSHT black screen nested resource owner progress

## 2026-07-25 baseline and root cause

Target: `build/skyengine build/mythroad/311019_1015_gsht.mrp`. No Xvfb was used; SDL dummy and bounded ARM diagnostics were used. Baseline P6 PPM is 240x320 and all 76,800 pixels are black (SHA-256 `1edcc2a5a6f7f596acf98d8fbd248c4175886dc8759e6d75ec652b339c2a53b6`); draw count stays zero.

The root package has 209 valid index entries. It contains `cfunction.ext` (8292 decoded bytes, SHA-256 prefix `94f9988ae8b5a6b3`), `game.ext` (131328 decoded bytes, SHA-256 prefix `44c3b610a0646022`), and `smsend.mrp`. The nested `smsend.mrp` has exactly one entry, `smsend.ext` (35576 decoded bytes).

Disassembly proves the wrapper dispatcher at `cfunction.ext+0x1C08` handles code 1 by calling `+0x4D8`; that function loads the `game.ext` string and calls the table[125] thunk at `+0x1564`. The thunk pushes `{r3,lr}`, invokes record slot 125 with `BLX r3`, and the bridge sees LR `0xE81575`. This request is wrapper-owned.

Bounded runtime diagnostics instead show `childScoped=1 ownerFile=0x226024 ownerLen=35576 found=0` for `game.ext`. `arm_ext_resource_owner_for_lr()` scans 16 words above SP after the direct wrapper LR fails and accepts a structurally plausible but stale `smsend.ext` BLX return left in reused stack storage. `aex_t125()` then restricts lookup to the recorded child package, where `game.ext` cannot exist. The subsequent timer loop reports `game_timer_head_zero`, and rendering is never entered.

The repair must preserve the existing WXMDLD behavior where a live child return is genuinely hidden behind a wrapper thunk. It must distinguish current live call frames from reused stack residue without package names, hashes, fixed application addresses, failure fallback, or root-package retry. Target verification requires root `game.ext` load, positive draw count, and a non-black/multicolor PPM; final verification must include existing regressions.

## 2026-07-25 live-frame discriminator

The first implementation journaled stack words written during the current `run_arm_with_sp()` execution. It fixed GSHT while restricted to the fixed wrapper stack, and it identified WXMDLD's live child return after heap-allocated private stacks were included. A second GSHT run then falsified the underlying rule: the stale `smsend.ext` word at `SP+0x24` had also been written earlier in the same emulator run. Current-run provenance distinguishes old callbacks, but not a completed frame reused later in one callback.

Disassembly provides the stronger ABI invariant. Both shared table veneers are symmetric Thumb leaf frames: `PUSH {r3,LR}`, a direct `BLX Rm` into the table bridge, then `POP {r3,PC}`. The active frame's saved LR is therefore the one exact slot computed from the matching PUSH/POP register list. GSHT has `SP+4 = 0xE804E9`, a wrapper return; the stale child-shaped value is unrelated at `SP+0x24`. WXMDLD has `SP+4 = 0x243297`, a live return into registered `flaengine.ext` code, whose preceding instruction is the required child `BLX Rm` call into the wrapper.

The implementation now decodes only that active leaf frame. It requires the direct wrapper return to follow `BLX Rm`, the next instruction to be `POP {...,PC}`, a matching bounded `PUSH {...,LR}`, and no intervening PUSH/POP or explicit SP adjustment. It derives the saved-LR address from the low-register count, then retains the existing child-code and child-call validation. It does not scan arbitrary stack words, retry another package, or inspect application/package identities.

Bounded verification before removing temporary diagnostics:

- GSHT: active slot candidate `0xE804E9`; `game.ext` loaded from the root package with decoded length 131328 and `childScoped=0`.
- GSHT: after LEFT_SOFT at the sound prompt, draw count reached 295; the 240x320 title PPM has 58,172 non-black pixels, 33 colors, and SHA-256 `0ff91e9562a1b63cd01738c924d9f6054905899f010fa8fc19037e0e4edde5d0`.
- WXMDLD: active slot candidate `0x243297`; owner recovery retained `ownerFile=0x227890 ownerLen=129312`; the cold/warm title E2E passed with its exact frame hashes and interactions.

## 2026-07-25 final verification

Temporary owner-candidate diagnostics were removed before the final build. The diagnostic-free SDL dummy artifact is `/tmp/skyengine-gsht-final.epEVZi`: the initial sound prompt is a 240x320 PPM with 398 non-black pixels and 2 colors; LEFT_SOFT advances to the full title frame with draw count 509, 58,099 non-black pixels, 32 colors, and SHA-256 `7ecdeb07d3edf49fa4db1ed464c4333b51a759b7b7602679658a6e312cc33f35`. The 21-line runtime log contains no Unicorn fault or temporary trace.

Compatibility verification used no retries. Focused WXMDLD, GJXWSMN, GGHJT, GWKDL, GZWDZJS, Sanguo, and Cookie tests all passed. TypeScript passed. CTest exited successfully but this build currently registers no CTest tests. The final parallel `pnpm vitest run test/e2e --retry=0 --reporter=verbose` passed all 31 files and 54 tests in 278.11 seconds.

The first full run exposed a pre-existing Cookie test assumption rather than a product regression: both the patched binary and a detached clean-HEAD binary create an empty `gsidbak` directory during startup, moving the last file-manager entry down one row. The E2E assertion now finds the established highlight color within the bottom file-row band; the unchanged subsequent browser launch, child-app frame, exit, and exact return-frame checks still prove the selected item and handoff behavior.

Final audit: the production change is limited to decoding the active Thumb leaf frame in `arm_ext_resource_owner_for_lr()`. It contains no application or package name, binary address, hash, root-package retry, failure-based alternate lookup, or foreground-state fallback.
