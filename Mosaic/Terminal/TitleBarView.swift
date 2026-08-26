import AppKit

final class TitleBarView: NSView {
    let titleLabel = NSTextField(labelWithString: "Terminal")
    let closeButton = NSButton()
    private let statusIndicator = StatusIndicatorView()

    /// Mirror the terminal's `ActivityState` (Docs/ADR/007-agent-attention-routing.md)
    /// into the status dot. No timer, no self-owned fade here: the reducer is the
    /// single source of truth for how long the indicator stays lit — this view just
    /// renders whatever `TerminalWindowView.onActivityChange` last reported. Attention
    /// persists until the reducer clears it (focus-while-visible or a keystroke).
    func setActivity(_ state: ActivityState) {
        statusIndicator.activityState = state
    }

    var onClose: (() -> Void)?
    /// Drag delta in screen points (not world).
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var lastDragLocation: CGPoint?
    private var wasDragging = false
    /// Local-space point from the most recent hitTest call (viewport-math correct).
    private var lastHitLocalPoint: CGPoint?
    private var isHoveringClose = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor

        // Close button (red circle)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 6
        closeButton.layer?.backgroundColor = NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1).cgColor
        closeButton.title = ""
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setFrameSize(NSSize(width: 12, height: 12))
        addSubview(closeButton)

        // Title label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = NSColor(white: 0.75, alpha: 1)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.alignment = .center
        addSubview(titleLabel)

        // Status indicator (command busy / exit code), right side opposite close button.
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusIndicator)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            closeButton.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: 12),
            statusIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        setHoveringClose(closeButton.frame.insetBy(dx: -4, dy: -4).contains(loc))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveringClose(false)
    }

    private func setHoveringClose(_ hovering: Bool) {
        guard hovering != isHoveringClose else { return }
        isHoveringClose = hovering
        if hovering {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor(white: 0.15, alpha: 0.9),
                .paragraphStyle: para,
                .baselineOffset: 0.5,
            ]
            closeButton.attributedTitle = NSAttributedString(string: "✕", attributes: attrs)
        } else {
            closeButton.attributedTitle = NSAttributedString(string: "")
        }
    }

    func applyTheme(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.cgColor
        titleLabel.textColor = foreground.withAlphaComponent(0.7)
        statusIndicator.foregroundColor = foreground
    }

    @objc private func closePressed() {
        onClose?()
    }

    // MARK: - Hit testing

    /// Return self for all clicks so mouseDown handles close vs drag without
    /// relying on NSButton's tracking (which breaks under layer transforms).
    override func hitTest(_ point: CGPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local) {
            lastHitLocalPoint = local
            return self
        }
        return nil
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(closeButton.frame, cursor: .arrow)
    }

    // MARK: - Drag to move window

    override func mouseDown(with event: NSEvent) {
        // Use the hit-test local point (viewport-math correct) rather than converting
        // event.locationInWindow, which doesn't account for the worldView layer transform.
        let loc = lastHitLocalPoint ?? convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(loc) {
            onClose?()
            return
        }
        lastDragLocation = event.locationInWindow
        wasDragging = false
        CanvasCursorManager.beginDrag(.closedHand, in: window)
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        guard let last = lastDragLocation else { return }
        wasDragging = true
        onDrag?(current.x - last.x, current.y - last.y)
        lastDragLocation = current
    }

    override func mouseUp(with event: NSEvent) {
        CanvasCursorManager.endDrag(in: window)
        lastDragLocation = nil
        if wasDragging { onDragEnded?() }
        wasDragging = false
    }
}

/// Small right-side dot that mirrors a terminal's `ActivityState` (ADR 007):
/// `quiet` → invisible; `busy` → dim steady dot; `needsAttention` → pulsing dot,
/// amber for a clean/unknown exit, red **triangle** for a nonzero exit — shape is
/// the non-color channel that distinguishes "waiting" from "waiting with an error"
/// at title-bar size. Colors are the ADR's fixed semantic palette (`Theme.swift`
/// exposes no accent token): there is no persistent "success" color distinct from
/// "waiting," since a finished command still needs the user's attention.
final class StatusIndicatorView: NSView {
    var activityState: ActivityState = .quiet {
        didSet {
            guard activityState != oldValue else { return }
            updateLayers()
        }
    }

    /// Theme foreground, used for the dim "busy" dot color. Set by `TitleBarView.applyTheme`.
    var foregroundColor: NSColor = .white {
        didSet {
            guard case .busy = activityState else { return }
            updateLayers()
        }
    }

    private let dotLayer = CAShapeLayer()
    private static let pulseAnimationKey = "attentionPulse"

    /// Semantic test surface: assert on what the view is *showing*, not on the
    /// `CAShapeLayer` that happens to render it, so a rendering-detail change
    /// (e.g. drawing in `draw(_:)` instead of a shape layer) doesn't break tests
    /// whose behavior didn't change.
    enum DotShape: Equatable { case dot, triangle }
    var isDotHidden: Bool { dotLayer.isHidden }
    var dotFillColor: CGColor? { dotLayer.fillColor }
    var dotShape: DotShape { isErrorTriangle ? .triangle : .dot }
    var isPulsing: Bool { dotLayer.animation(forKey: Self.pulseAnimationKey) != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        // Every state transition below must be instant (Docs/ADR/007-agent-attention-routing.md:
        // clearing attention is immediate, not eased) — disable CALayer's default implicit
        // animation on these properties once here, rather than wrapping every mutation in its
        // own `CATransaction`.
        dotLayer.actions = ["fillColor": NSNull(), "path": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(dotLayer)
        updateLayers()
    }

    override func layout() {
        super.layout()
        updatePath()
    }

    private func updatePath() {
        let side = min(bounds.width, bounds.height)
        // Guard against a zero/negative-size rect — `setup()` calls `updateLayers()` (which
        // computes the path) before this view has ever been laid out, when `bounds` is still
        // `.zero`; `insetBy(dx: 1, dy: 1)` on that turns negative, and CoreGraphics silently
        // produces NaN geometry for a degenerate ellipse/triangle rect rather than erroring.
        guard side > 2 else {
            dotLayer.path = nil
            return
        }
        let rect = CGRect(x: (bounds.width - side) / 2,
                          y: (bounds.height - side) / 2,
                          width: side, height: side).insetBy(dx: 1, dy: 1)
        dotLayer.path = isErrorTriangle ? Self.trianglePath(in: rect) : CGPath(ellipseIn: rect, transform: nil)
    }

    private var isErrorTriangle: Bool {
        if case .needsAttention(let exitCode) = activityState, let exitCode, exitCode != 0 {
            return true
        }
        return false
    }

    private static func trianglePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    private func updateLayers() {
        switch activityState {
        case .quiet:
            dotLayer.isHidden = true
            stopPulse()
        case .busy:
            dotLayer.isHidden = false
            dotLayer.fillColor = foregroundColor.withAlphaComponent(0.35).cgColor
            stopPulse()
        case .needsAttention:
            dotLayer.isHidden = false
            dotLayer.fillColor = (isErrorTriangle ? NSColor.systemRed : NSColor.systemOrange).cgColor
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                stopPulse()
            } else {
                startPulse()
            }
        }
        updatePath()
    }

    private func startPulse() {
        guard dotLayer.animation(forKey: Self.pulseAnimationKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(pulse, forKey: Self.pulseAnimationKey)
    }

    private func stopPulse() {
        dotLayer.removeAnimation(forKey: Self.pulseAnimationKey)
        dotLayer.opacity = 1
    }
}
