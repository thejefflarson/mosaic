import AppKit

final class TitleBarView: NSView {
    let titleLabel = NSTextField(labelWithString: "Terminal")
    let closeButton = NSButton()

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

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            closeButton.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor(white: 0.15, alpha: 0.9),
            ]
            closeButton.attributedTitle = NSAttributedString(string: "✕", attributes: attrs)
        } else {
            closeButton.attributedTitle = NSAttributedString(string: "")
        }
    }

    func applyTheme(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.cgColor
        titleLabel.textColor = foreground.withAlphaComponent(0.7)
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
