# CanvasTerm — Claude Code Context

## What this is

macOS desktop app: an infinite 2D spatial canvas where real PTY-backed terminal windows can be freely panned, zoomed, dragged, and resized. Built in Swift + AppKit + SwiftTerm. No web/JS runtime.

## Build

```bash
# Generate Xcode project (required after editing project.yml)
xcodegen generate

# Build from command line
xcodebuild build -scheme Mosaic -destination 'platform=macOS' -IDEPackageSupportDisableManifestSandbox=1

# Run tests
xcodebuild test -scheme MosaicTests -destination 'platform=macOS' -IDEPackageSupportDisableManifestSandbox=1

# Open in Xcode, then Cmd+B or Cmd+R
open Mosaic.xcodeproj
```

> **Note:** `-IDEPackageSupportDisableManifestSandbox=1` is required when running xcodebuild from a shell where `sandbox-exec` is blocked at the kernel level (e.g. inside Claude Code / ziplock).
>
> **ziplock one-time setup:** If running Claude Code under [ziplock](https://github.com/thejefflarson/ziplock), run this once on the host to suppress Xcode's own Package.swift manifest sandbox:
> ```bash
> defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
> ```
> ziplock sets `XBS_DISABLE_SANDBOXED_BUILDS=1` and `SWIFTPM_SANDBOX=0` automatically. The release script already passes `-IDEPackageSupportDisableManifestSandbox=1` to both xcodebuild invocations.

## Project structure

```
CanvasTerm/
├── App/                    # Entry point, AppDelegate, menu bar, ScriptingCommands
├── Canvas/                 # CanvasView (pan/zoom), CanvasViewController, CanvasGeometry
├── Terminal/               # TerminalController, TerminalWindowView, TitleBarView,
│                           #   ResizeHandleView, TerminalManager, TerminalSettings
├── Annotations/            # AnnotationController, AnnotationViews, CanvasTool,
│                           #   ToolPaletteView
├── Minimap/                # MinimapView overlay
├── Theming/                # Theme, ThemeEditorViewController
├── Persistence/            # WorkspaceSnapshot (Codable), WorkspaceStore, WorkspaceState
└── Utilities/              # CGRect/CGPoint extensions, SnapEngine, CanvasCursorManager
```

## Key architecture decisions

**Pan/zoom:** `CanvasView` holds a `FlippedView` (world space). Pan/zoom is applied as a `CGAffineTransform` on `worldView.layer`. All terminal windows are subviews positioned in world coordinates. No per-frame CPU work — CoreAnimation composites via Metal.

**Zoom-to-cursor math** is in `CanvasGeometry.swift` (`Viewport.zoomAround`). The invariant: world point under the cursor stays fixed.

**Viewport culling:** `CanvasView.updateCulling()` hides (`isHidden = true`) any terminal whose world-space frame doesn't intersect the visible rect. PTY process stays alive; only rendering is skipped.

**SwiftTerm integration:** `LocalProcessTerminalView` handles PTY spawn, I/O, and SIGWINCH. Do not override `terminalDelegate` externally — `LocalProcessTerminalView` sets it internally to pipe keystrokes to the PTY. Broadcast interception uses `InterceptingTerminalView` (subclass), which calls `super.send()` first.

**Concurrency:** Swift 6, `targeted` strict concurrency. All AppKit/UI work is `@MainActor`. `LocalProcessTerminalViewDelegate` methods are `nonisolated` and dispatch to main via `Task { @MainActor in }`. `WorkspaceStore` is `Sendable`; snapshots are value types passed to a serial `DispatchQueue`.

**Drag in world space:** Screen-space delta from `mouseDragged` must be divided by `currentZoom` before applying to world-space frame origin. Forgetting this makes windows "run away" at non-100% zoom.

**FlippedView:** `worldView` is a `FlippedView` (isFlipped = true) so Y increases downward, matching screen coordinate conventions for pan math.

**Snap engine:** `SnapEngine.swift` is a pure function (`snapRect`) that tests all 9 edge combinations (minX, midX, maxX × minY, midY, maxY) against reference rects and returns the best snap plus world-space guide line positions. `CanvasViewController.snapPosition()` calls it, converting guide positions to screen space for `SnapGuideOverlay`. During group drag, the bounding box of all selected items is snapped (not the dragged item's frame alone), and the resulting correction delta is applied uniformly to all peers.

**Controller pattern:** `TerminalController` and `AnnotationController` own their respective element sets and are created by `CanvasViewController`. Dependencies (snap, undo, theme) are injected as closures at init time so controllers never hold a back-reference to the VC. Mutations fire an `onChange` closure; the VC wires this to minimap refresh, selection ring update, and the 5-second save debounce.

**Undo model:** Undo actions are registered directly on `NSUndoManager` (via the responder chain) without grouping — each mutation is a single undoable step. Group-drag peer undos are registered in the same `mouseUp` event as the dragged item, so NSUndoManager's event-based coalescing bundles them into one Cmd+Z action automatically.

## Dependency

SwiftTerm via SPM: `https://github.com/migueldeicaza/SwiftTerm.git` (branch: main). Managed through xcodegen `project.yml`, not Package.swift (Package.swift exists only as a fallback compile check).

## Workspace persistence

Saves to `~/Library/Application Support/Mosaic/workspace.json` on a 5-second debounce after any change. Restores layout and working directories on launch. Terminal session content is not persisted (PTYs are always fresh).

**Shell intentionally not persisted:** on restore, Mosaic always reads `$SHELL` from the environment rather than replaying the shell recorded in the snapshot. This respects the user — if they ran `chsh` during a session, the next launch should honour that choice, not silently revert to the old shell. Do not "fix" this by persisting the shell path.

## Before pushing

Always run tests before pushing to avoid breaking CI:

```bash
xcodebuild test -scheme MosaicTests -destination 'platform=macOS' -IDEPackageSupportDisableManifestSandbox=1
```

## Release

```bash
./Scripts/release.sh v0.5.3
```

The script bumps `CFBundleShortVersionString` in `Info.plist`, commits it, then builds a signed + notarized DMG, pushes the git tag, and creates a GitHub release. The working tree must be clean before running (the plist commit is made by the script itself).
Apple Developer team ID `2PR729W8E3` is hardcoded as the default. Notarytool credentials
must be stored in the login keychain under the profile name `MosaicNotarization`:

```bash
xcrun notarytool store-credentials "MosaicNotarization" \
  --apple-id "you@example.com" \
  --team-id "2PR729W8E3" \
  --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com
```

## Known workarounds to revisit

**Xcode 26.4 test runner hang (added 2026-03-31):** `xcodebuild test` hangs for ~340 seconds with "The test runner hung before establishing connection" on Xcode 26.4 / macOS 26.4 regardless of test code. This is an Xcode 26.4 regression — CI uses Xcode 26.2 where tests run fine. Do not spend time debugging this locally; just push and let CI validate.

**Kitty keyboard arrow key fix (added 2026-03-25, revisit ~2026-04-08):** Claude Code v2.1.83
introduced a regression ("Fixed mouse tracking escape sequences leaking to shell prompt after exit")
that causes kitty keyboard mode to be pushed to all terminals, not just kitty-capable ones. SwiftTerm
honours the push and incorrectly encodes macOS cursor arrow keys as keypad arrows (CSI 57419u/57420u)
because macOS always sets the `.numericPad` flag on cursor arrow events. Workaround: a local
`NSEvent` monitor in `TerminalWindowView.setupTerminal()` strips `.numericPad` from the CGEvent
before SwiftTerm sees it. Once Claude Code fixes the regression, remove the monitor and its `deinit`
cleanup (`kittyArrowMonitor`).

## Planned features (not yet implemented)

- Minimap click/drag accuracy improvements
- Resize handle cursors (currently crosshair for all corner/edge handles)
