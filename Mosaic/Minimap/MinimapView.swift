import AppKit

/// A fixed overlay that renders a bird's-eye view of the entire canvas,
/// updated synchronously whenever the canvas state changes.
/// The top-left corner is a drag handle for resizing.
final class MinimapView: FlippedView {

    var onPanToWorld: ((CGPoint) -> Void)?
    var onResized: (() -> Void)?
    weak var canvasView: CanvasView?

    // Resize handle in the top-left corner
    private static let handleSize: CGFloat = 12
    private var resizeDragStart: NSPoint?
    private var sizeAtDragStart: CGSize?

    private var snapshot: NSImage?
    private var renderPending = false
    private var lastRenderTime: CFTimeInterval = 0
    private static let renderInterval: CFTimeInterval = 1.0 / 30.0

    // Updated by update(), consumed by renderSnapshot()
    private var terminalWindows: [TerminalWindowView] = []
    private var annotationViews: [AnnotationView] = []
    private var currentViewport = Viewport()
    private var focusedWindowID: UUID?
    private var flashingWindowIDs: Set<UUID> = []

    // Computed during render; used for click-to-pan
    private var worldExtent = CGRect(x: -200, y: -200, width: 2000, height: 1600)
    private var renderScale: CGFloat = 1
    private var renderOffset = CGPoint.zero

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
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor(white: 0.3, alpha: 1).cgColor
        layer?.borderWidth = 1
    }

    /// Flash a terminal's minimap representation briefly.
    /// Bypasses the render throttle so the flash is visible immediately.
    func flashTerminal(id: UUID) {
        flashingWindowIDs.insert(id)
        renderSnapshot()
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.flashingWindowIDs.remove(id)
            self.renderSnapshot()
            self.needsDisplay = true
        }
    }

    // MARK: - Update

    func update(viewport: Viewport, windows: [TerminalWindowView], annotations: [AnnotationView] = [],
                focusedWindow: TerminalWindowView? = nil) {
        currentViewport = viewport
        terminalWindows = windows
        annotationViews = annotations
        focusedWindowID = focusedWindow?.id
        guard !renderPending else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - lastRenderTime
        if elapsed < Self.renderInterval {
            // Schedule a trailing render so the final state is always drawn.
            renderPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.renderInterval - elapsed)) { [weak self] in
                guard let self else { return }
                self.lastRenderTime = CACurrentMediaTime()
                self.renderSnapshot()
                self.needsDisplay = true
                self.renderPending = false
            }
            return
        }
        lastRenderTime = now
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            self?.renderSnapshot()
            self?.needsDisplay = true
            self?.renderPending = false
        }
    }

    // MARK: - Rendering

    private func renderSnapshot() {
        let windows = terminalWindows
        let viewport = currentViewport

        // Compute world extent from all content (with margin)
        let allFrames = windows.map(\.frame) + annotationViews.map(\.frame)
        if !allFrames.isEmpty {
            let union = allFrames.dropFirst().reduce(allFrames[0]) { $0.union($1) }
            worldExtent = union.insetBy(dx: -120, dy: -80)
        }

        let scale = min(bounds.width / worldExtent.width,
                        bounds.height / worldExtent.height)
        renderScale = scale

        let scaledSize = CGSize(width: worldExtent.width * scale,
                                height: worldExtent.height * scale)
        let offsetX = (bounds.width  - scaledSize.width)  / 2
        let offsetY = (bounds.height - scaledSize.height) / 2
        renderOffset = CGPoint(x: offsetX, y: offsetY)

        // Snapshot annotations via layer.render — they're lightweight AppKit views.
        // Terminals are drawn as simple boxes to avoid GPU contention with SwiftTerm's Metal renderer.
        var annotImages: [(frame: CGRect, image: NSImage)] = []
        for av in annotationViews {
            guard !av.frame.isEmpty else { continue }
            let sz = av.bounds.size
            guard sz.width > 0, sz.height > 0 else { continue }
            // NSTextView-based annotations do lazy layout; force it before capture
            // so offscreen text views aren't rendered blank.
            av.prepareForMinimapCapture()
            // cacheDisplay captures screen-space pixels (Y-down) correctly,
            // unlike layer.render(in:) which renders in Y-up CA coordinates
            // and produces a flipped/squished result in our flipped drawing context.
            guard let bitmapRep = av.bitmapImageRepForCachingDisplay(in: av.bounds) else { continue }
            av.cacheDisplay(in: av.bounds, to: bitmapRep)
            let img = NSImage(size: sz)
            img.addRepresentation(bitmapRep)
            annotImages.append((av.frame, img))
        }
        let focusedID = focusedWindowID
        let flashing = flashingWindowIDs
        let windowFrames = windows.map { (
            frame: $0.frame,
            title: $0.currentTitle,
            isActive: $0.id == focusedID,
            isFlashing: flashing.contains($0.id),
            bgColor: $0.theme.terminalBackground,
            fgColor: $0.theme.terminalForeground
        ) }

        // Compose the minimap image using simple shapes — no layer.render() calls
        // so we don't interfere with SwiftTerm's Metal rendering pipeline.
        let canvasRef = canvasView
        let we = worldExtent
        let out = NSImage(size: bounds.size, flipped: true) { _ in
            // Background
            NSColor(white: 0.08, alpha: 1).setFill()
            NSRect(origin: .zero, size: self.bounds.size).fill()

            // Annotations — rendered via layer snapshot
            for (frame, img) in annotImages {
                let dest = NSRect(
                    x: (frame.minX - we.minX) * scale + offsetX,
                    y: (frame.minY - we.minY) * scale + offsetY,
                    width:  max(frame.width  * scale, 2),
                    height: max(frame.height * scale, 2)
                )
                img.draw(in: dest, from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: true, hints: nil)
            }

            // Terminal windows — themed body color with a small close dot, no title bar strip
            for wf in windowFrames {
                let frame = wf.frame
                let dest = NSRect(
                    x: (frame.minX - we.minX) * scale + offsetX,
                    y: (frame.minY - we.minY) * scale + offsetY,
                    width:  max(frame.width  * scale, 4),
                    height: max(frame.height * scale, 4)
                )
                // Body — use the terminal's actual theme background
                wf.bgColor.setFill()
                let bodyPath = NSBezierPath(roundedRect: dest, xRadius: 2, yRadius: 2)
                bodyPath.fill()
                // Close dot — small red circle top-left, like macOS traffic lights
                let dotD = min(dest.width * 0.06, dest.height * 0.09).clamped(to: 1.5...3.5)
                let dotX = dest.minX + dotD * 0.8
                let dotY = dest.minY + dotD * 0.8
                NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.9).setFill()
                NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotD, height: dotD)).fill()
                // Border — green for flashing, bright for focused, subtle otherwise
                if wf.isFlashing {
                    bodyPath.lineWidth = 2.0
                    NSColor.systemGreen.setStroke()
                } else if wf.isActive {
                    bodyPath.lineWidth = 0.5
                    let dark = wf.bgColor.isPerceivedDark
                    NSColor(white: dark ? 1.0 : 0.0, alpha: 0.9).setStroke()
                } else {
                    bodyPath.lineWidth = 0.5
                    wf.fgColor.withAlphaComponent(0.2).setStroke()
                }
                bodyPath.stroke()
            }

            // Viewport indicator
            if let cv = canvasRef {
                let vis = viewport.visibleWorldRect(screenSize: cv.bounds.size)
                let vp = NSRect(
                    x: (vis.minX - we.minX) * scale + offsetX,
                    y: (vis.minY - we.minY) * scale + offsetY,
                    width:  vis.width  * scale,
                    height: vis.height * scale
                )
                NSColor(white: 1, alpha: 0.12).setFill()
                vp.fill()
                NSColor(white: 1, alpha: 0.7).setStroke()
                let border = NSBezierPath(rect: vp)
                border.lineWidth = 1.5
                border.stroke()
            }
            return true
        }
        snapshot = out
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let snap = snapshot {
            snap.draw(in: bounds, from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor(white: 0.08, alpha: 1).setFill()
            bounds.fill()
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let handle = NSRect(x: 0, y: 0, width: Self.handleSize, height: Self.handleSize)
        let corner: NSCursor
        if #available(macOS 15, *) {
            corner = NSCursor.frameResize(position: .topLeft, directions: .all)
        } else {
            corner = .crosshair
        }
        addCursorRect(handle, cursor: corner)
        let rest = NSRect(x: Self.handleSize, y: 0,
                          width: bounds.width - Self.handleSize, height: bounds.height)
        addCursorRect(rest, cursor: .pointingHand)
    }

    // MARK: - Mouse: resize (top-left handle) or pan (everywhere else)

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if loc.x < Self.handleSize && loc.y < Self.handleSize {
            resizeDragStart = NSEvent.mouseLocation
            sizeAtDragStart = bounds.size
        } else {
            resizeDragStart = nil
            panToLocation(loc)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let start = resizeDragStart, let startSize = sizeAtDragStart {
            let current = NSEvent.mouseLocation
            // Drive width from the diagonal drag delta; derive height at exactly 16:9.
            let dx = -(current.x - start.x)
            let dy =  (current.y - start.y)
            let newW = (startSize.width + (dx + dy) / 2).clamped(to: 120...600)
            setMinimapSize(CGSize(width: newW, height: (newW * 10 / 16).rounded()))
            onResized?()
        } else {
            panToLocation(loc)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if resizeDragStart != nil {
            resizeDragStart = nil
            sizeAtDragStart = nil
            onResized?()
        }
    }

    private func panToLocation(_ loc: CGPoint) {
        let worldX = (loc.x - renderOffset.x) / renderScale + worldExtent.minX
        let worldY = (loc.y - renderOffset.y) / renderScale + worldExtent.minY
        onPanToWorld?(CGPoint(x: worldX, y: worldY))
    }

    /// Called by the parent to apply a persisted or programmatic size.
    /// Height is always derived from width at 16:9, ignoring any stored height.
    func setMinimapSize(_ size: CGSize) {
        let w = size.width.clamped(to: 120...600)
        widthConstraint?.constant  = w
        heightConstraint?.constant = (w * 10 / 16).rounded()
    }

    var widthConstraint:  NSLayoutConstraint?
    var heightConstraint: NSLayoutConstraint?
}
