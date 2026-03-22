import AppKit

/// An invisible hit-test area along a window edge or corner.
final class ResizeHandleView: NSView {

    enum Edge: CaseIterable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    let edge: Edge
    /// Delta is in screen space; caller converts to world space.
    var onResize: ((CGFloat, CGFloat) -> Void)?
    var onResizeBegan: (() -> Void)?
    var onResizeEnded: (() -> Void)?

    private var lastDragLocation: CGPoint?
    private var wasDragging = false

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private let handleThickness: CGFloat = 6

    /// Attach this handle's constraints to `parent` (the TerminalWindowView).
    func installConstraints(in parent: NSView) {
        let t = handleThickness
        var cs: [NSLayoutConstraint]
        switch edge {
        case .topLeft:
            cs = [leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                  topAnchor.constraint(equalTo: parent.topAnchor),
                  widthAnchor.constraint(equalToConstant: t * 2),
                  heightAnchor.constraint(equalToConstant: t * 2)]
        case .top:
            cs = [leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: t * 2),
                  trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -t * 2),
                  topAnchor.constraint(equalTo: parent.topAnchor),
                  heightAnchor.constraint(equalToConstant: t)]
        case .topRight:
            cs = [trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                  topAnchor.constraint(equalTo: parent.topAnchor),
                  widthAnchor.constraint(equalToConstant: t * 2),
                  heightAnchor.constraint(equalToConstant: t * 2)]
        case .left:
            cs = [leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                  topAnchor.constraint(equalTo: parent.topAnchor, constant: t * 2),
                  bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -t * 2),
                  widthAnchor.constraint(equalToConstant: t)]
        case .right:
            cs = [trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                  topAnchor.constraint(equalTo: parent.topAnchor, constant: t * 2),
                  bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -t * 2),
                  widthAnchor.constraint(equalToConstant: t)]
        case .bottomLeft:
            cs = [leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                  bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                  widthAnchor.constraint(equalToConstant: t * 2),
                  heightAnchor.constraint(equalToConstant: t * 2)]
        case .bottom:
            cs = [leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: t * 2),
                  trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -t * 2),
                  bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                  heightAnchor.constraint(equalToConstant: t)]
        case .bottomRight:
            cs = [trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                  bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                  widthAnchor.constraint(equalToConstant: t * 2),
                  heightAnchor.constraint(equalToConstant: t * 2)]
        }
        NSLayoutConstraint.activate(cs)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
        wasDragging = false
        CanvasCursorManager.beginDrag(cursorForEdge(edge), in: window)
        onResizeBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        guard let last = lastDragLocation else { return }
        wasDragging = true
        let dx = current.x - last.x
        let dy = current.y - last.y
        onResize?(dx, dy)
        lastDragLocation = current
    }

    override func mouseUp(with event: NSEvent) {
        CanvasCursorManager.endDrag(in: window)
        lastDragLocation = nil
        if wasDragging { onResizeEnded?() }
        wasDragging = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorForEdge(edge))
    }

    private func cursorForEdge(_ edge: Edge) -> NSCursor {
        switch edge {
        case .topLeft, .bottomRight:
            if #available(macOS 15.0, *) {
                let pos: NSCursor.FrameResizePosition = edge == .topLeft ? .topLeft : .bottomRight
                return NSCursor.frameResize(position: pos, directions: .all)
            }
            return .crosshair
        case .topRight, .bottomLeft:
            if #available(macOS 15.0, *) {
                let pos: NSCursor.FrameResizePosition = edge == .topRight ? .topRight : .bottomLeft
                return NSCursor.frameResize(position: pos, directions: .all)
            }
            return .crosshair
        case .top,  .bottom: return .resizeUpDown
        case .left, .right:  return .resizeLeftRight
        }
    }
}
