import CoreGraphics

/// Viewport state: what region of world-space is visible and at what zoom.
struct Viewport {
    var panX: CGFloat = 0
    var panY: CGFloat = 0
    var zoom: CGFloat = 1.0

    static let zoomMin: CGFloat = 0.1
    static let zoomMax: CGFloat = 3.0

    /// Convert a screen-space point to world-space.
    func screenToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - panX) / zoom, y: (p.y - panY) / zoom)
    }

    /// Convert a world-space point to screen-space.
    func worldToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + panX, y: p.y * zoom + panY)
    }

    /// Apply zoom centered on a screen-space anchor point.
    mutating func zoomAround(screenAnchor: CGPoint, factor: CGFloat) {
        let worldAnchor = screenToWorld(screenAnchor)
        zoom = (zoom * factor).clamped(to: Viewport.zoomMin...Viewport.zoomMax)
        panX = screenAnchor.x - worldAnchor.x * zoom
        panY = screenAnchor.y - worldAnchor.y * zoom
    }

    /// Pan by a screen-space delta.
    mutating func pan(dx: CGFloat, dy: CGFloat) {
        panX += dx
        panY += dy
    }

    /// World-space rect that is currently visible given a screen size.
    func visibleWorldRect(screenSize: CGSize) -> CGRect {
        let origin = screenToWorld(.zero)
        let corner = screenToWorld(CGPoint(x: screenSize.width, y: screenSize.height))
        return CGRect(x: origin.x, y: origin.y,
                      width: corner.x - origin.x,
                      height: corner.y - origin.y)
    }

    /// Set pan/zoom so that `worldBounds` fills the screen with `padding` on each side.
    mutating func zoomToFit(worldBounds: CGRect, screenSize: CGSize, padding: CGFloat = 60) {
        guard worldBounds.width > 0, worldBounds.height > 0,
              screenSize.width > 0, screenSize.height > 0 else { return }
        let availW = screenSize.width  - padding * 2
        let availH = screenSize.height - padding * 2
        let z = min(availW / worldBounds.width, availH / worldBounds.height)
        zoom = z.clamped(to: Viewport.zoomMin...Viewport.zoomMax)
        panX = screenSize.width  / 2 - worldBounds.midX * zoom
        panY = screenSize.height / 2 - worldBounds.midY * zoom
    }
}

