# ADR 001 — Pan/Zoom via Bounds Transform

**Status:** Accepted
**Date:** 2026-03

## Context

The canvas needs to support infinite pan and zoom. Two approaches were considered:

1. **`CALayer.affineTransform`** on `worldView.layer` — apply a scale+translate matrix to the Metal-composited layer.
2. **`setBoundsOrigin` / `setBoundsSize`** on `worldView` (NSView bounds transform) — adjust AppKit's internal coordinate mapping.

## Decision

Use the **bounds transform** approach (option 2).

`worldView.setBoundsOrigin(screenToWorld(.zero))` and `setBoundsSize(CGSize(width: screenW/zoom, height: screenH/zoom))` together make AppKit's coordinate system report world-space values throughout the view hierarchy, without any custom math.

`CATransaction.setDisableActions(true)` is used around every bounds change to suppress implicit animations that would cause visual smearing.

## Consequences

**Positive:**
- AppKit's built-in hit-testing (`hitTest`, `convert(_:to:)`) works correctly in world space — no manual coordinate transformations needed in subviews.
- Terminal window drag math: `mouseDragged` delta divided by `currentZoom` works directly.
- Auto Layout within terminal windows remains unaffected — constraints are in the window's own coordinate space.
- No Metal/CoreAnimation synchronization issues from directly manipulating the layer transform while SwiftTerm is also rendering.

**Negative:**
- The `hitTest` override in `CanvasView` must still manually map screen → world to find which terminal is under the cursor. AppKit's default `hitTest` walks bounds, but we need reverse-sorted z-order traversal.
- `FlippedView` is required as the `worldView` container so Y increases downward (matching screen conventions). Without flipping, pan math inverts the Y axis.
- Changing bounds every frame (during pinch) triggers `setNeedsLayout` on subviews — mitigated because terminal windows use manual frame setting, not Auto Layout relative to worldView.
