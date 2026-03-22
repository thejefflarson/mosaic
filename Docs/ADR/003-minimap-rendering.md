# ADR 003 — Minimap Rendering Strategy

**Status:** Accepted
**Date:** 2026-03

## Context

The minimap needs to show a bird's-eye view of all canvas content (terminals + annotations) at ~60 fps. Three approaches were considered:

1. **`layer.render(in:)` for all views** — capture each view's CALayer into a CGContext.
2. **Metal screenshot** — `MTKView` snapshot of the entire canvas.
3. **Hybrid: vector boxes for terminals, `layer.render` for annotations.**

## Decision

Use the **hybrid** approach (option 3):
- Terminal windows are drawn as simple dark rectangles with a lighter title bar strip.
- Annotation views use `layer.render(in:)` — captured into `NSImage` and composited.

Updates are batched via `CVDisplayLink` with an `isDirty` flag: rendering only runs when content has changed, at most once per display frame.

## Why not `layer.render(in:)` for terminals?

SwiftTerm renders terminal content via a **Metal pipeline** (`MTKView` or `CAMetalLayer`). Calling `layer.render(in:)` on a Metal-backed layer while the GPU is actively compositing causes:
- Visual corruption (torn frames, black rectangles).
- Potential GPU synchronization stalls.
- On Apple Silicon, crossing the CPU/GPU boundary for every minimap frame is prohibitively expensive.

## Why not a Metal screenshot of the full canvas?

- Would require synchronizing with the GPU command queue on every frame.
- The minimap size is small (180×120 pt) — full-canvas GPU capture is massive overkill.
- Introduces a dependency on the rendering pipeline that would complicate future architectural changes.

## Concurrency

`CVDisplayLinkSetOutputCallback` runs on a private display-link thread (not main). The `isDirty` and `renderPending` flags are accessed from both threads.

**Fix:** `OSAllocatedUnfairLock<(isDirty: Bool, renderPending: Bool)>` wraps both flags. The display link callback reads and clears `isDirty` atomically; the main thread sets it in `update(viewport:windows:annotations:)`.

Actual rendering (`renderSnapshot()`) always runs on the main thread via `DispatchQueue.main.async`.

## Consequences

- Terminal minimap representations are approximations — they show position and size but not content.
- Annotation thumbnails are accurate (AppKit views render correctly via `layer.render`).
- The viewport indicator (white rectangle) shows the currently visible region of world space.
- Clicking/dragging the minimap pans the canvas to the clicked world position.
