import AppKit
import CoreGraphics

// MARK: - Comparable

extension Comparable {
    /// Clamp a value to a closed range.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - NSColor

extension NSColor {
    /// True when the color's perceptual luminance is below 50%.
    var isPerceivedDark: Bool {
        guard let rgb = usingColorSpace(.deviceRGB) else { return true }
        let lum = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return lum < 0.5
    }
}

// MARK: - CGRect

extension CGRect {
    /// Convenience initialiser that accepts a center point and size.
    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2,
                  y: center.y - size.height / 2,
                  width: size.width,
                  height: size.height)
    }

    /// Returns the smallest rect spanning two arbitrary points (order-independent).
    static func between(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
