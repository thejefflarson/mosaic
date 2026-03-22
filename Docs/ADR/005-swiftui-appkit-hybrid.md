# ADR 005 — SwiftUI / AppKit Hybrid

**Status:** Accepted
**Date:** 2026-03

## Context

The app is primarily AppKit, but SwiftUI offers compelling advantages for certain UI surfaces (declarative state, `ColorPicker`, `Picker`, material backgrounds, `@Observable`). The question is where to draw the line.

## Decision Criteria

### Use SwiftUI when:
- The view is **pure UI state** — no world-space coordinates, no CoreAnimation transforms, no custom gesture math.
- The view benefits from SwiftUI built-ins: `ColorPicker`, `Picker`, `Form`, `ScrollView`, `.ultraThinMaterial`, `keyboardShortcut`.
- The view is **modal or floating** (panel/sheet) — lifecycle is simple and state can live in `ObservableObject`.

### Keep AppKit when:
- The view **lives in world space** — positioned by world coordinates, affected by pan/zoom transforms (terminals, annotations).
- The view requires **custom `hitTest` overrides** — AppKit's responder chain needs direct subclassing.
- The view does **custom CoreAnimation or Metal rendering** — SwiftTerm's `LocalProcessTerminalView`, `MinimapView.draw`.
- The view has **complex drag tracking** tied to screen/world coordinate math — `TitleBarView`, `ResizeHandleView`, `AnnotationView`.

## Applied decisions

| View | Framework | Reason |
|------|-----------|--------|
| `ThemeEditorViewController` | SwiftUI (`NSHostingController`) | Pure UI state, ColorPicker, Picker, Export/Import panels |
| `ToolPaletteView` | SwiftUI (`NSHostingView`) | HUD with toggle buttons, `.ultraThinMaterial`, pure UI state |
| `CanvasView` | AppKit | World-space, custom `hitTest`, bounds transform pan/zoom |
| `TerminalWindowView` | AppKit | SwiftTerm integration, world-space, custom drag/resize |
| `TitleBarView` | AppKit | Custom `hitTest` override for layer-transform-aware drag |
| `ResizeHandleView` | AppKit | Drag math tied to world-space zoom |
| `MinimapView` | AppKit | Custom `draw(_:)`, CVDisplayLink, CoreGraphics rendering |
| `AnnotationViews` | AppKit | World-space subviews, custom drag, `draw(_:)` for arrow/freehand |

## Integration patterns

**`NSHostingController<V>`** — used for `ThemeEditorViewController`. The SwiftUI view is the `contentViewController` of an `NSPanel`. Callbacks (`onApply`, `onSave`) are forwarded through the `ObservableObject` model.

**`NSHostingView<V>`** — used for `ToolPaletteView`. The SwiftUI view is embedded as a subview of an `NSView` that participates in Auto Layout normally. This is the correct pattern when an AppKit parent needs a SwiftUI child without a view controller.

## Consequences

- The `ThemeEditorModel` class is `internal` (not `private`) because `NSHostingController<ThemeEditorView>` must be accessible at the same access level as its generic parameter. This is a Swift compiler constraint, not a design choice.
- SwiftUI `ColorPicker` on macOS opens the system color panel — exactly what we want.
- Future views that are "mostly UI" (e.g., a workspace browser, preferences panel) should default to SwiftUI.
