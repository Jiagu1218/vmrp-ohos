---
title: "Native modal menu touch event contract"
tags: ["native-ui", "menu", "touch", "mr-mouse", "white"]
created: 2026-08-07T11:06:48.508Z
updated: 2026-08-07T11:24:00.000Z
sources: []
links: []
category: pattern
confidence: high
schemaVersion: 1
---

# Native modal menu touch event contract

The shared runtime receives touch-compatible input as MR_MOUSE_DOWN/UP/MOVE with x in p0 and y in p1. Platform overlays own these events and must translate a completed gesture into overlay ABI events instead of passing raw coordinates to the guest.

For mr_menuShow, upstream MTK mrp_localui.cpp connects VcpListMenu item taps to MR_MENU_SELECT(index) and the back toolbar to MR_MENU_RETURN. White cfunction.ext likewise handles menu event codes 4/5 rather than raw mouse events.

Implementation invariant: capture the target on DOWN, update focus for an item, and commit only when UP hits the same target. This prevents the UP paired with a guest DOWN that opened a menu from selecting it, and prevents a callback-created child overlay from receiving the old gesture. Hit geometry must derive from the same layout constants used to render the menu.

The E2E CLICK command already injects SDL mouse DOWN/UP and is the canonical test path; no separate TOUCH protocol is required. SDL_FINGER support and dialog touch are separate scopes.

## Verified implementation

On 2026-08-07 the shared runtime began passing both coordinates to the native menu filter. The menu captures a target on DOWN, changes item focus immediately, and posts `MR_MENU_SELECT` or `MR_MENU_RETURN` only when UP hits that same target. A refresh cancels the action target while retaining ownership of the eventual UP.

`test/e2e/white/settings.test.ts` keeps the keyboard workflow and adds item, Back, and OK touch coverage with full-frame PPM comparisons. The focused target passed 2/2 tests; the complete E2E set passed 36 files and 63 tests. Native and shared-only builds plus TypeScript checking passed without Xvfb or full trace.
