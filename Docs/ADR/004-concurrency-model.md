# ADR 004 — Concurrency Model

**Status:** Accepted
**Date:** 2026-03

## Context

Swift 6 strict concurrency checking (`SWIFT_STRICT_CONCURRENCY = targeted`) requires explicit actor isolation for all mutable state shared across concurrency domains. The app has three concurrency domains:

1. **Main thread / `@MainActor`** — all AppKit UI work.
2. **CVDisplayLink callback thread** — minimap dirty flag, FPS frame timing.
3. **Serial utility queue** — `WorkspaceStore` JSON encoding/writing.

## Decision

### All UI is `@MainActor`
`CanvasViewController`, `CanvasView`, `TerminalManager`, `MinimapView`, `AppDelegate`, and all annotation/terminal views are `@MainActor` (either explicitly annotated or implied by subclassing `NSView`/`NSViewController`).

### `LocalProcessTerminalViewDelegate` methods are `nonisolated`
SwiftTerm's delegate protocol is not actor-isolated. Delegate callbacks (e.g., `processTerminated`) are called from SwiftTerm's internal threads. These methods are marked `nonisolated` and dispatch back to main via `Task { @MainActor in ... }`.

### Cross-thread flags use `OSAllocatedUnfairLock`
The minimap's `isDirty`/`renderPending` flags are written from the CVDisplayLink thread and read/written from main. Wrapped in `OSAllocatedUnfairLock` (available macOS 13+) — a non-blocking, fair OS lock appropriate for short critical sections.

### `WorkspaceStore` is `Sendable` via a serial `DispatchQueue`
`WorkspaceStore.save(_:)` dispatches JSON encoding + atomic file write to a private serial `DispatchQueue`. `WorkspaceSnapshot` is a `Sendable` value type (struct), so capture-by-value is safe with no copies of mutable state. `flushSynchronously()` uses `queue.sync { }` to drain the queue on app termination.

### No `async`/`await` at the top level (deliberate)
The app is fully callback/delegate driven. Introducing `async` functions at the UIlayer would require `@MainActor` annotations throughout and Task creation in gesture handlers — adding complexity without benefit for this use case. Where async-style work is needed, `Task { @MainActor in }` is used locally.

## Consequences

- `nonisolated(unsafe)` was briefly used for MinimapView flags — replaced with `OSAllocatedUnfairLock` to eliminate the data race.
- CVDisplayLink callbacks use `Unmanaged<T>.passUnretained(self).toOpaque()` — a well-known pattern for passing `self` through C callback APIs. The VC/view must outlive the display link; `deinit` stops the link before deallocation.
- `WorkspaceStore.load()` is intentionally synchronous — it only runs once at startup, before any concurrent work begins, so there is no contention risk.
