# ADR 002 — SwiftTerm Integration

**Status:** Accepted
**Date:** 2026-03

## Context

We need real PTY-backed terminal emulation inside each canvas window. Options were:
1. **Roll our own** PTY + VT100 parser.
2. **SwiftTerm** — an MIT-licensed Swift library providing `LocalProcessTerminalView`, a full VT100/VT220 emulator with AppKit and Metal rendering.
3. **WebView + xterm.js** — embed a WebView per terminal.

## Decision

Use **SwiftTerm** via Swift Package Manager, pinned to `branch: main` (managed through XcodeGen's `project.yml`, not a standalone `Package.swift`).

Specifically, we subclass `LocalProcessTerminalView` as `InterceptingTerminalView` to intercept outgoing keystrokes for broadcast mode, rather than interposing at a higher layer.

## Key constraints discovered during integration

### `terminalDelegate` must not be overridden externally
`LocalProcessTerminalView` sets `terminalDelegate = self` internally to route keystrokes from the `TerminalView` layer to the PTY. Overriding this externally breaks the PTY input pipe.

### Broadcast mode loop prevention
`TerminalView.send(data:)` → PTY → renders output → `TerminalView` calls its delegate `send(source:data:)`. `InterceptingTerminalView.send(source:data:)` is that delegate callback. If we naively call `termView.send(data:)` inside it (to fan-out to other terminals), we trigger another delegate call on the *source* terminal, creating an infinite loop.

**Fix:** `suppressBroadcast: Bool` flag on `InterceptingTerminalView`. `sendInput(_:)` sets it before calling `send(data:)`, clears it after. The `send(source:data:)` override skips its `onSendData` callback when the flag is set.

### `nativeForegroundColor` / `nativeBackgroundColor`
These SwiftTerm properties control not just the terminal content colors but also the scrollbar track background. They must be set before `addSubview` for initial rendering, and again via `applyTheme` for live changes.

### Scrollbar appearance
The internal `NSScroller` uses `.legacy` style and inherits its track color from the view's AppKit appearance. Setting `termView.appearance = NSAppearance(named: .darkAqua)` forces dark rendering regardless of the system-wide appearance.

### Scrollback extraction
`getScrollInvariantLine(row:)` with negative row indices accesses scrollback history. `BufferLine.translateToString(trimRight: true)` extracts plain text. Lines are joined with `\r\n` (not `\n`) to reset the cursor column between lines.

## Consequences

- No control over SwiftTerm's Metal rendering pipeline — we cannot `layer.render(in:)` terminal views in the minimap without GPU contention. Minimap draws terminal boxes as simple shapes instead.
- SwiftTerm's public API surface is relatively stable but not comprehensive. Buffer access via `getScrollInvariantLine` is implementation-adjacent.
- Upgrading SwiftTerm (`branch: main`) may break buffer API usage.
