---
title: "Optwar modal resume stale wrapper timer owner"
tags: ["optwar", "arm-ext", "timer", "wrapper", "modal", "e2e"]
created: 2026-07-31T11:04:19.217Z
updated: 2026-07-31T11:49:57.589Z
sources: []
links: ["gghjt-modal-timer-and-cold-extraction-regressions.md"]
category: debugging
confidence: high
schemaVersion: 1
---

# Optwar modal resume stale wrapper timer owner

Symptom: after cancelling token payment and returning to the game, draw rate rose from about 10 to 28-32 draws/s indefinitely. Timer diagnostics proved the guest repeatedly requested 10ms through cfunction.ext LR 0xE848FE, always with the wrapper as timer owner; this was not host clamping or competing callers.

Root cause: when modal suspend depth changed from >0 to 0, wrapper resume rearmed a bookkeeping timer but the host retained the wrapper owner after the foreground child had closed. Every code=2 then replayed wrapper cleanup and starved the primary game timer. Commit 8ac50f8 had removed an older close-edge owner release.

Generic fix: at the arm_ext_call suspend-depth >0-to-0 edge, release timer_p_addr/timer_helper_addr only when the callback is code=2, a real foreground child closed, the wrapper queue is live at that exact boundary, and the owner is still the wrapper. Queue liveness is sampled before restoring the wrapper foreground snapshot. DOTA's legitimate close is code=1 with a live wrapper queue; GGHJT also has a code=2 close, but its wrapper queue is empty. Neither may release ownership. Do not apply the transfer to arm_ext_call_dispatch, whose download/reopen queues still require wrapper ownership.

The per-module primary_resume_without_timer_owner flag carries this exact close classification across later recovery ticks. While active has returned to primary, recovery remains ownerless so routing enters the primary public helper; explicitly assigning primary jumps directly into its compact walker and freezes after four ticks. The flag is cleared on the next modal entry, and event closes, empty wrapper queues, dispatch closes, and newly active children retain wrapper ownership. No app-name check or interval clamp is used.

Verification: diagnostic artifact /tmp/skyengine-e2e-HCdDKk measured 20 draws/2s before payment and 61 draws/7s after resume; post-close timer requests remain 100ms. test/e2e/optwar/game-play.test.ts compares wall-clock-normalized rates over both a 7s stable window and its final 2s within 0.5x..1.5x, requires PPM movement during the final subwindow, and confirms the last frame remains in the game scene. The final state passes all six tests across Optwar game-play/game-prepare/exit-plugin, both DOTA plugin cases, and all five GGHJT download/reentry cases. The GXDZC payment/cancel click flow stayed alive without a runtime error when run against test/fixtures/gxdzc.mrp. See docs/optwar-resume-speedup.md and [[gghjt-modal-timer-and-cold-extraction-regressions]].
