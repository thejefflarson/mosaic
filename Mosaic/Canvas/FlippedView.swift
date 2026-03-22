import AppKit

/// An `NSView` subclass whose coordinate system is flipped so Y increases downward,
/// matching screen coordinate conventions for pan/zoom math.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
