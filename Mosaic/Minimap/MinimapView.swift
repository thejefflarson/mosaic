import AppKit
import CoreVideo
import os

/// A fixed overlay that renders a bird's-eye view of the entire canvas at ~60 fps,
/// synchronized to display frame boundaries via CVDisplayLink.
final class MinimapView: NSView {
    override var isFlipped: Bool { true }

    var onPanToWorld: ((CGPoint) -> Void)?
    weak var canvasView: CanvasView?

    private var snapshot: NSImage?
    private var displayLink: CVDisplayLink?

    /// Guards `isDirty` and `renderPending`, which are written from the CVDisplayLink
    /// callback thread and read/written from the main thread.
    private let renderFlags = OSAllocatedUnfairLock(initialState: (isDirty: false, renderPending: false))

    // Updated by update(), consumed by renderSnapshot()
    private var terminalWindows: [TerminalWindowView] = []
    private var annotationViews: [AnnotationView] = []
    private var currentViewport = Viewport()
    private var focusedWindowID: UUID?

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

    // MARK: - Display link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }

        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ctx -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            let view = Unmanaged<MinimapView>.fromOpaque(ctx).takeUnretainedValue()
            // Check and update flags atomically to avoid a data race with the main thread.
            let shouldRender = view.renderFlags.withLock { state -> Bool in
                guard state.isDirty, !state.renderPending else { return false }
                state.isDirty = false
                state.renderPending = true
                return true
            }
            guard shouldRender else { return kCVReturnSuccess }
            DispatchQueue.main.async {
                view.renderSnapshot()
                view.needsDisplay = true
                view.renderFlags.withLock { $0.renderPending = false }
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    // MARK: - Update

    func update(viewport: Viewport, windows: [TerminalWindowView], annotations: [AnnotationView] = [],
                focusedWindow: TerminalWindowView? = nil) {
        currentViewport = viewport
        terminalWindows = windows
        annotationViews = annotations
        focusedWindowID = focusedWindow?.id
        renderFlags.withLock { $0.isDirty = true }
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
            guard !av.frame.isEmpty, let layer = av.layer else { continue }
            let sz = av.bounds.size
            guard sz.width > 0, sz.height > 0 else { continue }
            let img = NSImage(size: sz)
            img.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext { layer.render(in: ctx) }
            img.unlockFocus()
            annotImages.append((av.frame, img))
        }
        let focusedID = focusedWindowID
        let windowFrames = windows.map { (
            frame: $0.frame,
            title: $0.currentTitle,
            isActive: $0.id == focusedID,
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
                         fraction: 1, respectFlipped: false, hints: nil)
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
                // Close dot — small circle top-left, colored from the foreground at low opacity
                let dotD = max(min(dest.width * 0.08, dest.height * 0.12, 5), 2)
                let dotX = dest.minX + dotD * 0.8
                let dotY = dest.minY + dotD * 0.8
                wf.fgColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotD, height: dotD)).fill()
                // Border — bright blue for the focused terminal, subtle otherwise
                if wf.isActive {
                    NSColor.systemBlue.setStroke()
                    bodyPath.lineWidth = 1.5
                } else {
                    wf.fgColor.withAlphaComponent(0.2).setStroke()
                    bodyPath.lineWidth = 0.5
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

    // MARK: - Click/drag to pan

    override func mouseDown(with event: NSEvent) { panToEvent(event) }
    override func mouseDragged(with event: NSEvent) { panToEvent(event) }

    private func panToEvent(_ event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let worldX = (loc.x - renderOffset.x) / renderScale + worldExtent.minX
        let worldY = (loc.y - renderOffset.y) / renderScale + worldExtent.minY
        onPanToWorld?(CGPoint(x: worldX, y: worldY))
    }
}
