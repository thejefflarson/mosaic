import CoreGraphics

extension CGRect {
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
