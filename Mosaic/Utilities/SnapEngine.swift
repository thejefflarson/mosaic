import CoreGraphics

// MARK: - Snap result

/// The output of the snap algorithm: a corrected frame plus optional world-space
/// coordinates for snap guide rendering.
struct SnapResult {
    var rect: CGRect
    /// World-space X of the snapped vertical guide line (nil = no horizontal snap).
    var worldX: CGFloat?
    /// World-space Y of the snapped horizontal guide line (nil = no vertical snap).
    var worldY: CGFloat?
}

// MARK: - Core algorithm

/// Pure snap function — no side effects, directly unit-testable.
///
/// For each axis, considers all 3×3 pairings of the moving element's
/// [min, mid, max] lines against the reference element's [min, mid, max] lines.
/// The closest pairing within `threshold` wins; ties go to the smallest delta.
///
/// Returns the adjusted rect and the world-space positions of any triggered guides.
func snapRect(_ proposed: CGRect, to others: [CGRect], threshold: CGFloat) -> SnapResult {
    let movingX: [CGFloat] = [proposed.minX, proposed.midX, proposed.maxX]
    let movingY: [CGFloat] = [proposed.minY, proposed.midY, proposed.maxY]

    var bestDX: CGFloat?
    var bestWorldX: CGFloat?
    var bestDY: CGFloat?
    var bestWorldY: CGFloat?

    for other in others {
        let refX: [CGFloat] = [other.minX, other.midX, other.maxX]
        let refY: [CGFloat] = [other.minY, other.midY, other.maxY]

        for px in movingX {
            for ox in refX {
                let d = ox - px
                if abs(d) < threshold, bestDX == nil || abs(d) < abs(bestDX!) {
                    bestDX = d
                    bestWorldX = ox
                }
            }
        }
        for py in movingY {
            for oy in refY {
                let d = oy - py
                if abs(d) < threshold, bestDY == nil || abs(d) < abs(bestDY!) {
                    bestDY = d
                    bestWorldY = oy
                }
            }
        }
    }

    var result = proposed
    if let dx = bestDX { result.origin.x += dx }
    if let dy = bestDY { result.origin.y += dy }
    return SnapResult(rect: result, worldX: bestWorldX, worldY: bestWorldY)
}
