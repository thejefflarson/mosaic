import AppKit

// MARK: - Base class

/// Abstract base for all annotation views positioned in world space.
/// Handles drag-to-move when the pointer tool is active.
class AnnotationView: NSView {
    let annotationID = UUID()
    weak var canvasView: CanvasView?
    var onChanged: (() -> Void)?
    /// Fired after a completed drag; carries (fromFrame, toFrame).
    var onDragEnded: ((CGRect, CGRect) -> Void)?

    var snapFrame: ((CGRect, ResizeHandleView.Edge?) -> CGRect)?
    var clearSnapGuides: (() -> Void)?

    private var dragStart: CGPoint?
    private var frameAtDragStart: CGRect?
    fileprivate(set) var didDrag = false
    var frameBeforeResize: CGRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }   // match world-space y-down

    // MARK: - Delete (right-click)

    var onDelete: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        guard canvasView?.activeTool == .pointer else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Delete", action: #selector(deleteAnnotation), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func deleteAnnotation() { onDelete?() }

    // MARK: - Cursor feedback

    override func resetCursorRects() {
        guard canvasView?.activeTool == .pointer else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: - Drag to move (pointer tool)

    private static let dragThreshold: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        guard canvasView?.activeTool == .pointer else { return }
        dragStart = event.locationInWindow
        frameAtDragStart = frame
        didDrag = false
        CanvasCursorManager.beginDrag(.closedHand, in: window)
    }

    override func mouseDragged(with event: NSEvent) {
        guard canvasView?.activeTool == .pointer,
              let start = dragStart,
              let origin = frameAtDragStart else { return }
        let loc = event.locationInWindow
        let screenDist = hypot(loc.x - start.x, loc.y - start.y)
        guard didDrag || screenDist >= AnnotationView.dragThreshold else { return }
        if !didDrag {
            didDrag = true
        }
        let zoom = canvasView?.currentZoom ?? 1
        let totalDX =  (loc.x - start.x) / zoom
        let totalDY = -(loc.y - start.y) / zoom
        let proposed = CGRect(origin: CGPoint(x: origin.origin.x + totalDX,
                                              y: origin.origin.y + totalDY),
                              size: origin.size)
        let snapped = snapFrame?(proposed, nil) ?? proposed
        // Pass only the incremental delta so subclasses don't accumulate totals.
        let incrDX = snapped.origin.x - frame.origin.x
        let incrDY = snapped.origin.y - frame.origin.y
        frame.origin = snapped.origin
        didMoveByDelta(dx: incrDX, dy: incrDY)
        onChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        clearSnapGuides?()
        CanvasCursorManager.endDrag(in: window)
        if didDrag, let from = frameAtDragStart, frame != from {
            onDragEnded?(from, frame)
        }
        dragStart = nil
        frameAtDragStart = nil
        didDrag = false
    }

    /// Override in subclasses that store absolute world points (arrow, freehand).
    func didMoveByDelta(dx: CGFloat, dy: CGFloat) {}

    // MARK: - Resize handles

    /// Override in subclasses that support resizing.
    func handleResize(edge: ResizeHandleView.Edge, screenDX: CGFloat, screenDY: CGFloat) {}

    /// Call from subclass `setup()` to install the 8 resize handles.
    func setupResizeHandles() {
        for edge in ResizeHandleView.Edge.allCases {
            let h = ResizeHandleView(edge: edge)
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
            h.installConstraints(in: self)
            h.onResizeBegan = { [weak self] in self?.frameBeforeResize = self?.frame ?? .zero }
            h.onResize = { [weak self] dx, dy in self?.handleResize(edge: edge, screenDX: dx, screenDY: dy) }
            h.onResizeEnded = { [weak self] in
                guard let self else { return }
                clearSnapGuides?()
                if frame != frameBeforeResize { onDragEnded?(frameBeforeResize, frame) }
            }
        }
    }

    // MARK: - Snapshot support

    func toSnapshot() -> AnnotationSnapshot? { nil }
}

// MARK: - Text label

final class TextAnnotationView: AnnotationView, NSTextFieldDelegate {
    let textField = NSTextField()
    var textColor: NSColor = .white { didSet { textField.textColor = textColor } }
    var annotationFont: NSFont = NSFont.systemFont(ofSize: 148, weight: .regular) {
        didSet { textField.font = annotationFont; sizeToFitText() }
    }

    init(at worldPt: CGPoint, text: String = "") {
        super.init(frame: CGRect(x: worldPt.x, y: worldPt.y, width: 800, height: 175))
        setup(text: text)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup(text: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(text: String) {
        textField.stringValue = text
        textField.isEditable = true
        textField.isBordered = false
        textField.drawsBackground = false
        textField.textColor = NSColor.white
        textField.font = annotationFont
        textField.placeholderString = "Text"
        textField.delegate = self
        addSubview(textField)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        textField.shadow = shadow
        sizeToFitText()
    }

    private func sizeToFitText() {
        let font = textField.font ?? annotationFont
        let str = textField.stringValue.isEmpty ? (textField.placeholderString ?? "Text") : textField.stringValue
        let measured = (str as NSString).size(withAttributes: [.font: font])
        frame.size = CGSize(width: max(measured.width + 24, 160),
                            height: max(measured.height + 16, font.pointSize + 10))
        textField.frame = bounds
    }

    func beginEditing() {
        window?.makeFirstResponder(textField)
    }

    func controlTextDidChange(_ obj: Notification) {
        sizeToFitText()
        onChanged?()
    }

    // Escape dismisses editing and returns focus to the canvas.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            window?.makeFirstResponder(superview)
            return true
        }
        return false
    }

    // In pointer mode, route all hits to self so the text field doesn't steal
    // the drag. On a double-click (no drag), we start editing in mouseUp.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard canvasView?.activeTool == .pointer else { return super.hitTest(point) }
        return bounds.contains(point) ? self : nil
    }

    private var pendingEditOnUp = false

    override func mouseDown(with event: NSEvent) {
        pendingEditOnUp = event.clickCount == 2
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if pendingEditOnUp && !didDrag {
            beginEditing()
        }
        pendingEditOnUp = false
    }

    override func toSnapshot() -> AnnotationSnapshot? {
        AnnotationSnapshot(
            id: annotationID,
            kind: .text,
            x: frame.origin.x, y: frame.origin.y,
            width: frame.width, height: frame.height,
            content: textField.stringValue
        )
    }
}

// MARK: - Sticky note

final class StickyNoteView: AnnotationView {

    enum NoteColor: String, CaseIterable {
        case yellow, blue, pink, green
        var nsColor: NSColor {
            switch self {
            case .yellow: return NSColor(red: 1.0,  green: 0.95, blue: 0.5,  alpha: 1)
            case .blue:   return NSColor(red: 0.6,  green: 0.82, blue: 1.0,  alpha: 1)
            case .pink:   return NSColor(red: 1.0,  green: 0.7,  blue: 0.8,  alpha: 1)
            case .green:  return NSColor(red: 0.7,  green: 1.0,  blue: 0.7,  alpha: 1)
            }
        }
    }

    var noteColor: NoteColor = .yellow { didSet { applyColor() } }
    var themeForeground: NSColor = NSColor(white: 0.1, alpha: 1) { didSet { textView.textColor = themeForeground } }
    var themeBackground: NSColor = NSColor(red: 1.0, green: 0.95, blue: 0.5, alpha: 1) { didSet { applyColor() } }
    let textView = NSTextView()
    private let titleBar = NSView()

    private let minSize = CGSize(width: 120, height: 80)

    init(at worldPt: CGPoint, color: NoteColor = .yellow, text: String = "") {
        super.init(frame: CGRect(x: worldPt.x, y: worldPt.y, width: 200, height: 160))
        noteColor = color
        setup(text: text)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup(text: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(text: String) {
        layer?.cornerRadius = 6

        // Title bar drag strip
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleBar.wantsLayer = true
        addSubview(titleBar)
        NSLayoutConstraint.activate([
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Text area — plain NSTextView with autolayout (no scroll view)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = themeForeground
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = text
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        applyColor()
        setupResizeHandles()
    }

    override func handleResize(edge: ResizeHandleView.Edge, screenDX: CGFloat, screenDY: CGFloat) {
        guard let cv = canvasView else { return }
        let zoom = cv.currentZoom
        let dx = screenDX / zoom
        let dy = -screenDY / zoom

        var r = frame
        switch edge {
        case .topLeft:
            r.origin.x += dx; r.size.width  -= dx
            r.origin.y += dy; r.size.height -= dy
        case .top:
            r.origin.y += dy; r.size.height -= dy
        case .topRight:
            r.size.width  += dx
            r.origin.y    += dy; r.size.height -= dy
        case .left:
            r.origin.x += dx; r.size.width -= dx
        case .right:
            r.size.width += dx
        case .bottomLeft:
            r.origin.x    += dx; r.size.width  -= dx
            r.size.height += dy
        case .bottom:
            r.size.height += dy
        case .bottomRight:
            r.size.width  += dx
            r.size.height += dy
        }

        r.size.width  = max(r.size.width,  minSize.width)
        r.size.height = max(r.size.height, minSize.height)

        if let snap = snapFrame {
            let snapped = snap(r, edge)
            let sdx = snapped.origin.x - r.origin.x
            let sdy = snapped.origin.y - r.origin.y

            let dragsRight  = edge == .right  || edge == .topRight   || edge == .bottomRight
            let dragsLeft   = edge == .left   || edge == .topLeft    || edge == .bottomLeft
            let dragsBottom = edge == .bottom || edge == .bottomLeft || edge == .bottomRight
            let dragsTop    = edge == .top    || edge == .topLeft    || edge == .topRight

            if dragsRight       { r.size.width  += sdx }
            else if dragsLeft   { r.origin.x    += sdx; r.size.width  -= sdx }
            if dragsBottom      { r.size.height += sdy }
            else if dragsTop    { r.origin.y    += sdy; r.size.height -= sdy }

            r.size.width  = max(r.size.width,  minSize.width)
            r.size.height = max(r.size.height, minSize.height)
        }

        frame = r
        onChanged?()
    }

    private func applyColor() {
        // Tint the theme background toward the selected note hue
        let bg = themeBackground.blended(withFraction: 0.35, of: noteColor.nsColor) ?? themeBackground
        layer?.backgroundColor = bg.cgColor
        titleBar.layer?.backgroundColor = bg.withAlphaComponent(0.7).cgColor
        textView.textColor = themeForeground
    }

    func beginEditing() {
        window?.makeFirstResponder(textView)
    }

    override func toSnapshot() -> AnnotationSnapshot? {
        AnnotationSnapshot(
            id: annotationID,
            kind: .stickyNote,
            x: frame.origin.x, y: frame.origin.y,
            width: frame.width, height: frame.height,
            content: textView.string,
            colorName: noteColor.rawValue
        )
    }
}

// MARK: - Arrow

final class ArrowAnnotationView: AnnotationView {
    private var worldStart: CGPoint
    private var worldEnd: CGPoint
    var strokeColor: NSColor = .white

    init(start: CGPoint, end: CGPoint) {
        worldStart = start
        worldEnd = end
        super.init(frame: ArrowAnnotationView.calcFrame(start: start, end: end))
    }

    override init(frame: NSRect) {
        worldStart = frame.origin
        worldEnd = CGPoint(x: frame.maxX, y: frame.maxY)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateEnd(_ worldPt: CGPoint) {
        worldEnd = worldPt
        frame = ArrowAnnotationView.calcFrame(start: worldStart, end: worldEnd)
        setNeedsDisplay(bounds)
    }

    private static func calcFrame(start: CGPoint, end: CGPoint) -> CGRect {
        let pad: CGFloat = 12
        let minX = min(start.x, end.x) - pad
        let minY = min(start.y, end.y) - pad
        let maxX = max(start.x, end.x) + pad
        let maxY = max(start.y, end.y) + pad
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let ox = frame.origin.x, oy = frame.origin.y
        let ls = CGPoint(x: worldStart.x - ox, y: worldStart.y - oy)
        let le = CGPoint(x: worldEnd.x   - ox, y: worldEnd.y   - oy)

        let path = NSBezierPath()
        path.move(to: ls)
        path.line(to: le)
        path.lineWidth = 2
        path.lineCapStyle = .round

        let angle = atan2(le.y - ls.y, le.x - ls.x)
        let aLen: CGFloat = 12, aAng: CGFloat = .pi / 6
        path.move(to: CGPoint(x: le.x - aLen * cos(angle - aAng), y: le.y - aLen * sin(angle - aAng)))
        path.line(to: le)
        path.line(to: CGPoint(x: le.x - aLen * cos(angle + aAng), y: le.y - aLen * sin(angle + aAng)))

        strokeColor.setStroke()
        path.stroke()
    }

    override func didMoveByDelta(dx: CGFloat, dy: CGFloat) {
        worldStart.x += dx; worldStart.y += dy
        worldEnd.x   += dx; worldEnd.y   += dy
    }

    override func toSnapshot() -> AnnotationSnapshot? {
        AnnotationSnapshot(
            id: annotationID,
            kind: .arrow,
            x: frame.origin.x, y: frame.origin.y,
            width: frame.width, height: frame.height,
            points: [
                PointSnapshot(x: worldStart.x, y: worldStart.y),
                PointSnapshot(x: worldEnd.x,   y: worldEnd.y),
            ]
        )
    }
}

// MARK: - Freehand

final class FreehandAnnotationView: AnnotationView {
    private var localPoints: [CGPoint] = []
    var strokeColor: NSColor = .white
    var strokeWidth: CGFloat = 2

    private static let pad: CGFloat = 8

    init(at worldPt: CGPoint) {
        let p = FreehandAnnotationView.pad
        super.init(frame: CGRect(x: worldPt.x - p, y: worldPt.y - p, width: p * 2, height: p * 2))
        localPoints.append(CGPoint(x: p, y: p))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    func addWorldPoint(_ worldPt: CGPoint) {
        expandFrame(including: worldPt)
        let local = CGPoint(x: worldPt.x - frame.origin.x, y: worldPt.y - frame.origin.y)
        localPoints.append(local)
        setNeedsDisplay(bounds)
    }

    private func expandFrame(including worldPt: CGPoint) {
        let p = FreehandAnnotationView.pad
        let needed = CGRect(x: worldPt.x - p, y: worldPt.y - p, width: p * 2, height: p * 2)
        let expanded = frame.union(needed)
        guard expanded != frame else { return }
        // Translate existing local points so they remain visually correct
        let shift = CGPoint(x: frame.origin.x - expanded.origin.x,
                            y: frame.origin.y - expanded.origin.y)
        localPoints = localPoints.map { CGPoint(x: $0.x + shift.x, y: $0.y + shift.y) }
        frame = expanded
    }

    override func draw(_ dirtyRect: NSRect) {
        guard localPoints.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: localPoints[0])
        for pt in localPoints.dropFirst() { path.line(to: pt) }
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        strokeColor.setStroke()
        path.stroke()
    }

    /// World points for snapshot persistence.
    var worldPoints: [CGPoint] {
        localPoints.map { CGPoint(x: $0.x + frame.origin.x, y: $0.y + frame.origin.y) }
    }

    /// Restore from world points (used when loading from snapshot).
    func loadWorldPoints(_ pts: [CGPoint]) {
        guard !pts.isEmpty else { return }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let p = FreehandAnnotationView.pad
        let f = CGRect(x: xs.min()! - p, y: ys.min()! - p,
                       width: xs.max()! - xs.min()! + p * 2,
                       height: ys.max()! - ys.min()! + p * 2)
        frame = f
        localPoints = pts.map { CGPoint(x: $0.x - f.origin.x, y: $0.y - f.origin.y) }
        setNeedsDisplay(bounds)
    }

    override func didMoveByDelta(dx: CGFloat, dy: CGFloat) {
        // localPoints are relative to frame.origin, so moving the frame is sufficient.
        // No update needed — draw() always offsets by frame.origin.
    }

    override func toSnapshot() -> AnnotationSnapshot? {
        AnnotationSnapshot(
            id: annotationID,
            kind: .freehand,
            x: frame.origin.x, y: frame.origin.y,
            width: frame.width, height: frame.height,
            points: worldPoints.map { PointSnapshot(x: $0.x, y: $0.y) },
            lineWidth: strokeWidth
        )
    }
}

// MARK: - Image

final class ImageAnnotationView: AnnotationView {
    private let imageView = NSImageView()
    /// Absolute path to the saved PNG in Application Support/Mosaic/Images/.
    private var savedImagePath: String?
    /// Width / height of the source image. Maintained during resize.
    let aspectRatio: CGFloat

    init(at worldPt: CGPoint, image: NSImage) {
        let s = image.size
        let ar = (s.width > 0 && s.height > 0) ? s.width / s.height : 1
        // Scale down proportionally to fit within 400×300
        let scale = min(1, min(400 / max(1, s.width), 300 / max(1, s.height)))
        let size = CGSize(width: s.width * scale, height: s.height * scale)
        aspectRatio = ar
        super.init(frame: CGRect(origin: worldPt, size: size))
        setup(image: image)
        savedImagePath = Self.persistImage(image, id: annotationID)
    }

    override init(frame: NSRect) {
        aspectRatio = frame.width / max(1, frame.height)
        super.init(frame: frame)
        setup(image: NSImage())
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(image: NSImage) {
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setupResizeHandles()
    }


    override func handleResize(edge: ResizeHandleView.Edge, screenDX: CGFloat, screenDY: CGFloat) {
        guard let cv = canvasView else { return }
        let zoom = cv.currentZoom
        let dx = screenDX / zoom
        let dy = -screenDY / zoom
        let minW: CGFloat = 80

        var r = frame
        switch edge {
        case .topLeft:
            r.origin.x += dx; r.size.width  -= dx
            r.origin.y += dy; r.size.height -= dy
        case .top:
            r.origin.y += dy; r.size.height -= dy
        case .topRight:
            r.size.width  += dx
            r.origin.y    += dy; r.size.height -= dy
        case .left:
            r.origin.x += dx; r.size.width -= dx
        case .right:
            r.size.width += dx
        case .bottomLeft:
            r.origin.x    += dx; r.size.width  -= dx
            r.size.height += dy
        case .bottom:
            r.size.height += dy
        case .bottomRight:
            r.size.width  += dx
            r.size.height += dy
        }

        // Lock aspect ratio. Top/bottom edges drive from height; all others from width.
        switch edge {
        case .top, .bottom:
            r.size.height = max(minW / aspectRatio, r.size.height)
            r.size.width  = r.size.height * aspectRatio
            if edge == .top { r.origin.y = frame.maxY - r.size.height }
        default:
            r.size.width  = max(minW, r.size.width)
            r.size.height = r.size.width / aspectRatio
            // Restore anchored edges for handles that move origin
            switch edge {
            case .left, .bottomLeft:
                r.origin.x = frame.maxX - r.size.width
            case .topRight:
                r.origin.y = frame.maxY - r.size.height
            case .topLeft:
                r.origin.x = frame.maxX - r.size.width
                r.origin.y = frame.maxY - r.size.height
            default: break
            }
        }

        frame = r
        onChanged?()
    }

    /// Write image to disk as PNG; returns the file path or nil on failure.
    private static func persistImage(_ image: NSImage, id: UUID) -> String? {
        let url = WorkspaceStore.shared.imagesDirectory
            .appendingPathComponent("\(id.uuidString).png")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: url)
        return url.path
    }

    override func toSnapshot() -> AnnotationSnapshot? {
        guard let path = savedImagePath else { return nil }
        return AnnotationSnapshot(
            id: annotationID,
            kind: .image,
            x: frame.origin.x, y: frame.origin.y,
            width: frame.width, height: frame.height,
            imagePath: path
        )
    }
}
