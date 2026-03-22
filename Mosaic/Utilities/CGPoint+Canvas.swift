import CoreGraphics

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Union that handles the case where self is .null.
    func safeUnion(_ other: CGRect) -> CGRect {
        isNull ? other : union(other)
    }
}

extension Collection where Element == CGRect {
    func boundingBox() -> CGRect {
        reduce(.null) { $0.safeUnion($1) }
    }
}
