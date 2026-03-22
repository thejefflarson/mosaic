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
/// `movingX`/`movingY`: restrict which lines of the proposed rect participate in snapping.
/// Pass nil to test all three (min/mid/max). Pass a subset for resize operations where
/// only the dragged edge should snap (e.g. right-edge drag → `movingX: [proposed.maxX]`).
func snapRect(_ proposed: CGRect, to others: [CGRect], threshold: CGFloat,
              movingX: [CGFloat]? = nil, movingY: [CGFloat]? = nil) -> SnapResult {
    let testX = movingX ?? [proposed.minX, proposed.midX, proposed.maxX]
    let testY = movingY ?? [proposed.minY, proposed.midY, proposed.maxY]

    var bestDX: CGFloat?
    var bestWorldX: CGFloat?
    var bestXIsMid = false
    var bestDY: CGFloat?
    var bestWorldY: CGFloat?
    var bestYIsMid = false

    for other in others {
        let refX: [CGFloat] = [other.minX, other.midX, other.maxX]
        let refY: [CGFloat] = [other.minY, other.midY, other.maxY]

        for px in testX {
            for (xi, ox) in refX.enumerated() {
                let d = ox - px
                let isMid = xi == 1
                if abs(d) < threshold {
                    if bestDX == nil || abs(d) < abs(bestDX!) || (abs(d) == abs(bestDX!) && bestXIsMid && !isMid) {
                        bestDX = d; bestWorldX = ox; bestXIsMid = isMid
                    }
                }
            }
        }
        for py in testY {
            for (yi, oy) in refY.enumerated() {
                let d = oy - py
                let isMid = yi == 1
                if abs(d) < threshold {
                    if bestDY == nil || abs(d) < abs(bestDY!) || (abs(d) == abs(bestDY!) && bestYIsMid && !isMid) {
                        bestDY = d; bestWorldY = oy; bestYIsMid = isMid
                    }
                }
            }
        }
    }

    var result = proposed
    if let dx = bestDX { result.origin.x += dx }
    if let dy = bestDY { result.origin.y += dy }
    return SnapResult(rect: result, worldX: bestWorldX, worldY: bestWorldY)
}
