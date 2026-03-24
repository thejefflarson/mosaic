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
├── App/                    # Entry point, AppDelegate, menu bar
├── Canvas/                 # CanvasView (pan/zoom), CanvasViewController, Viewport math
├── Terminal/               # TerminalWindowView, TitleBarView, ResizeHandleView, TerminalManager
├── Minimap/                # MinimapView overlay
├── Persistence/            # WorkspaceSnapshot (Codable), WorkspaceStore
└── Utilities/              # CGRect extensions, keyboard shortcut helpers
```

## Key architecture decisions

**Pan/zoom:** `CanvasView` holds a `FlippedView` (world space). Pan/zoom is applied as a `CGAffineTransform` on `worldView.layer`. All terminal windows are subviews positioned in world coordinates. No per-frame CPU work — CoreAnimation composites via Metal.

**Zoom-to-cursor math** is in `CanvasGeometry.swift` (`Viewport.zoomAround`). The invariant: world point under the cursor stays fixed.

**Viewport culling:** `CanvasView.updateCulling()` hides (`isHidden = true`) any terminal whose world-space frame doesn't intersect the visible rect. PTY process stays alive; only rendering is skipped.

**SwiftTerm integration:** `LocalProcessTerminalView` handles PTY spawn, I/O, and SIGWINCH. Do not override `terminalDelegate` externally — `LocalProcessTerminalView` sets it internally to pipe keystrokes to the PTY. Broadcast interception uses `InterceptingTerminalView` (subclass), which calls `super.send()` first.

**Concurrency:** Swift 6, `targeted` strict concurrency. All AppKit/UI work is `@MainActor`. `LocalProcessTerminalViewDelegate` methods are `nonisolated` and dispatch to main via `Task { @MainActor in }`. `WorkspaceStore` is `Sendable`; snapshots are value types passed to a serial `DispatchQueue`.

**Drag in world space:** Screen-space delta from `mouseDragged` must be divided by `currentZoom` before applying to world-space frame origin. Forgetting this makes windows "run away" at non-100% zoom.

**FlippedView:** `worldView` is a `FlippedView` (isFlipped = true) so Y increases downward, matching screen coordinate conventions for pan math.

## Dependency

SwiftTerm via SPM: `https://github.com/migueldeicaza/SwiftTerm.git` (branch: main). Managed through xcodegen `project.yml`, not Package.swift (Package.swift exists only as a fallback compile check).

## Workspace persistence

Saves to `~/Library/Application Support/Mosaic/workspace.json` on a 5-second debounce after any change. Restores layout and working directories on launch. Terminal session content is not persisted (PTYs are always fresh).

## Before pushing

Always run tests before pushing to avoid breaking CI:

```bash
xcodebuild test -scheme MosaicTests -destination 'platform=macOS' -IDEPackageSupportDisableManifestSandbox=1
```

## Release

```bash
./Scripts/release.sh v0.3.0
```

Builds a signed + notarized DMG, pushes the git tag, and creates a GitHub release.
Apple Developer team ID `2PR729W8E3` is hardcoded as the default. Notarytool credentials
must be stored in the login keychain under the profile name `MosaicNotarization`:

```bash
xcrun notarytool store-credentials "MosaicNotarization" \
  --apple-id "you@example.com" \
  --team-id "2PR729W8E3" \
  --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com
```

## Planned features (not yet implemented)

- Minimap click/drag accuracy improvements
- Resize handle cursors (currently crosshair for corners)
