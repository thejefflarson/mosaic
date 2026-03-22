import AppKit

/// The infinite canvas view. `worldView` fills the canvas frame; pan/zoom is
/// applied via `setBoundsOrigin` / `setBoundsSize` so AppKit's coordinate system
/// stays correct — no CALayer transform trickery needed.
final class CanvasView: NSView {
    override var isFlipped: Bool { true }

    // MARK: - Public state

    private(set) var viewport = Viewport()

    /// When true the canvas declines first-responder so broadcast-mode typing
    /// continues going to the focused terminal regardless of where you click.
    var broadcastModeActive: Bool = false
    override var acceptsFirstResponder: Bool { !broadcastModeActive }

    /// Called whenever the viewport changes so the minimap can update.
    var onViewportChanged: ((Viewport) -> Void)?

    /// Called when user double-clicks on the canvas background.
    var onBackgroundDoubleClick: ((CGPoint) -> Void)?

    /// All TerminalWindowViews and AnnotationViews are children of this view (world space).
    let worldView = FlippedView()

    // MARK: - Tool state

    var activeTool: CanvasTool = .pointer

    /// Fires with the world-space point on mouseDown with a non-pointer tool.
    var onToolBegan: ((CanvasTool, CGPoint) -> Void)?
    /// Fires with the world-space point on mouseDragged with a non-pointer tool.
    var onToolMoved: ((CanvasTool, CGPoint) -> Void)?
    /// Fires with the world-space point on mouseUp with a non-pointer tool.
    var onToolEnded: ((CanvasTool, CGPoint) -> Void)?

    // MARK: - Selection rect (delete tool drag)

    private let selectionLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor   = NSColor(white: 1, alpha: 0.06).cgColor
        l.strokeColor = NSColor.white.cgColor
        l.lineWidth   = 1.5
        l.lineDashPattern = [6, 4]
        l.isHidden = true
        return l
    }()

    func setSelectionRect(_ rect: CGRect?) {
        if let rect {
            selectionLayer.isHidden = false
            selectionLayer.path = CGPath(rect: rect, transform: nil)
            selectionLayer.lineWidth = 1.5 / viewport.zoom
        } else {
            selectionLayer.isHidden = true
            selectionLayer.path = nil
        }
    }

    // MARK: - Init

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

        // worldView covers the canvas exactly; bounds transform provides pan/zoom.
        worldView.wantsLayer = true   // own CALayer so bounds changes don't disturb sibling layers
        worldView.frame = bounds
        worldView.autoresizingMask = [.width, .height]
        addSubview(worldView)

        worldView.layer?.addSublayer(selectionLayer)
        setupGestureRecognizers()
    }

    // MARK: - Gesture recognizers

    private func setupGestureRecognizers() {
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    private var pinchAnchor: CGPoint?

    @objc private func handlePinch(_ gr: NSMagnificationGestureRecognizer) {
        if gr.state == .began {
            pinchAnchor = convert(gr.location(in: self), from: nil)
        }
        let anchor = pinchAnchor ?? convert(gr.location(in: self), from: nil)
        let factor = 1 + gr.magnification
        gr.magnification = 0
        viewport.zoomAround(screenAnchor: anchor, factor: factor)
        applyViewport()
        if gr.state == .ended || gr.state == .cancelled || gr.state == .failed {
            pinchAnchor = nil
        }
    }

    // MARK: - Scroll wheel (zoom + pan)

    /// True while a trackpad scroll gesture that began over the canvas background is ongoing.
    /// Prevents a terminal drifting under the cursor from stealing the pan gesture.
    private var canvasPanGestureActive = false

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            let loc = convert(event.locationInWindow, from: nil)
            let worldPt = convert(loc, to: worldView)
            let overTerminal = worldView.subviews.contains {
                ($0 as? TerminalWindowView)?.frame.contains(worldPt) == true
            }
            canvasPanGestureActive = !overTerminal
        } else if event.phase == .ended || event.phase == .cancelled {
            canvasPanGestureActive = false
        }

        let isTrackpad = event.phase != [] || event.momentumPhase != []
        let forcePan = NSEvent.modifierFlags.contains(.command)
        if isTrackpad && !canvasPanGestureActive && !forcePan { return }

        if event.phase == [] && event.momentumPhase == [] && !event.hasPreciseScrollingDeltas {
            // Traditional (non-trackpad) scroll wheel → zoom around cursor
            let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.05 : 0.95
            let screenPt = convert(event.locationInWindow, from: nil)
            viewport.zoomAround(screenAnchor: screenPt, factor: factor)
        } else {
            viewport.pan(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        }
        applyViewport()
    }


    // MARK: - Mouse (pan by dragging background)

    private var lastDragPoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        // With fullSizeContentView + transparent title bar, the canvas covers the title bar
        // area. If the click is above contentLayoutRect, route to window dragging rather
        // than starting a canvas pan.
        if let win = window, event.locationInWindow.y > win.contentLayoutRect.maxY {
            win.performDrag(with: event)
            return
        }

        let loc = convert(event.locationInWindow, from: nil)
        let worldPt = convert(loc, to: worldView)

        // Non-pointer tools intercept all clicks on the canvas background
        if activeTool != .pointer {
            onToolBegan?(activeTool, worldPt)
            return
        }

        let onTerminal = worldView.subviews.reversed().contains {
            ($0 as? TerminalWindowView)?.frame.contains(worldPt) == true
        }
        guard !onTerminal else { return }
        lastDragPoint = loc
        if event.clickCount == 2 {
            onBackgroundDoubleClick?(worldPt)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if activeTool != .pointer {
            let loc = convert(event.locationInWindow, from: nil)
            let worldPt = convert(loc, to: worldView)
            onToolMoved?(activeTool, worldPt)
            return
        }
        guard lastDragPoint != nil else { return }
        viewport.pan(dx: event.deltaX, dy: event.deltaY)
        applyViewport()
    }

    override func mouseUp(with event: NSEvent) {
        if activeTool != .pointer {
            let loc = convert(event.locationInWindow, from: nil)
            let worldPt = convert(loc, to: worldView)
            onToolEnded?(activeTool, worldPt)
            return
        }
        lastDragPoint = nil
    }

    // MARK: - Viewport application

    func applyViewport() {
        // Disable implicit CALayer animations so bounds changes take effect
        // immediately — without this, animated transitions cause visual artifacts
        // (ghosting, smearing) especially when zoomed out.
        // Single atomic assignment avoids the intermediate repaint that the
        // two-step setBoundsOrigin/setBoundsSize sequence causes (the root of zoom wiggle).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let zoom = viewport.zoom
        let origin = viewport.screenToWorld(.zero)
        worldView.bounds = CGRect(
            origin: origin,
            size: CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
        )
        CATransaction.commit()
        onViewportChanged?(viewport)
    }

    func setViewport(_ vp: Viewport) {
        viewport = vp
        applyViewport()
    }

    func addTerminal(_ tw: TerminalWindowView) {
        worldView.addSubview(tw)
    }

    /// Adds an annotation below all terminal windows.
    func addAnnotation(_ av: AnnotationView) {
        av.canvasView = self
        if let firstTerminal = worldView.subviews.first(where: { $0 is TerminalWindowView }) {
            worldView.addSubview(av, positioned: .below, relativeTo: firstTerminal)
        } else {
            worldView.addSubview(av)
        }
    }

    func removeAnnotation(_ av: AnnotationView) {
        av.removeFromSuperview()
    }

    func activateTerminal(_ tw: TerminalWindowView) {
        activate(tw)
    }

    func setCanvasBackground(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyViewport()
    }

    // MARK: - Active terminal

    private(set) weak var activeTerminal: TerminalWindowView?

    private func activate(_ tw: TerminalWindowView) {
        guard tw !== activeTerminal else { return }
        activeTerminal?.isActive = false
        tw.isActive = true
        activeTerminal = tw
    }

    // MARK: - Hit testing

    /// Route events to the correct terminal using viewport-aware coordinate math.
    /// `point` arrives in superview space; we convert to screen space, then world space.
    ///
    /// Three special cases are handled before the general z-order walk:
    /// 1. **Cmd+scroll** — forced pan; always route to `self` so the canvas receives the event
    ///    even when the cursor is over a terminal.
    /// 2. **Active canvas pan gesture** — once a two-finger pan begins over the background,
    ///    keep routing scroll events here so a terminal drifting under the cursor can't steal
    ///    the gesture mid-stream.
    /// 3. **Drawing tool active** — all clicks/drags go to `self` so the tool can create
    ///    annotations; terminals do not receive the events.
    override func hitTest(_ point: CGPoint) -> NSView? {
        let screenPt = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(screenPt) else { return nil }

        // ⌘ held: force-route scroll/drag events to canvas for panning over terminals.
        if NSEvent.modifierFlags.contains(.command),
           NSApp.currentEvent?.type == .scrollWheel {
            return self
        }

        // During an active canvas pan gesture, keep routing scroll events here so
        // a terminal drifting under the cursor doesn't steal the pan.
        if canvasPanGestureActive, NSApp.currentEvent?.type == .scrollWheel {
            return self
        }

        // Map screen → world using bounds transform (no manual viewport math needed).
        let worldPt = convert(screenPt, to: worldView)

        // When a drawing tool is active, canvas captures events — but let sibling HUD
        // views (tool palette, minimap) above us in z-order keep priority.
        // Use hitTest on each sibling so pass-through overlays (snap guide overlay etc.)
        // that return nil from hitTest don't accidentally block the canvas.
        if activeTool != .pointer {
            if let parent = superview {
                let parentPt = convert(screenPt, to: parent)
                for sib in parent.subviews.reversed() {
                    guard sib !== self else { break }   // only siblings in front of canvas
                    if sib.hitTest(parentPt) != nil { return nil }
                }
            }
            return self
        }

        for sub in worldView.subviews.reversed() {
            if let tw = sub as? TerminalWindowView, tw.frame.contains(worldPt) {
                if NSEvent.pressedMouseButtons != 0 {
                    worldView.addSubview(tw)   // bring to front
                    activate(tw)
                }
                if let deepest = tw.hitTest(worldPt) { return deepest }
                return tw
            }
            if let av = sub as? AnnotationView, av.frame.contains(worldPt) {
                if let deepest = av.hitTest(worldPt) { return deepest }
                return av
            }
        }
        return self
    }

    /// Current zoom for use by terminal windows during drag/resize.
    var currentZoom: CGFloat { viewport.zoom }
}

