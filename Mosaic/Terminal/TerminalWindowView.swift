import AppKit
import SwiftTerm

/// Thin subclass that intercepts outgoing key data for broadcast mode
/// while still calling super to let the PTY receive input normally.
final class InterceptingTerminalView: LocalProcessTerminalView {
    var onSendData: (@Sendable (ArraySlice<UInt8>) -> Void)?
    /// Set to true while programmatically sending broadcast data so we don't
    /// re-trigger onSendData and cause an infinite broadcast loop.
    var suppressBroadcast = false

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)   // PTY receives input as normal
        if !suppressBroadcast {
            onSendData?(data)                    // broadcast hook
        }
    }
}

private let titleBarHeight: CGFloat = 28
private let minSize = CGSize(width: 200, height: 120)

/// A free-floating terminal window in world space.
/// Contains a title bar, a SwiftTerm LocalProcessTerminalView, and 8 resize handles.
final class TerminalWindowView: NSView {

    // MARK: - Identity

    let id = UUID()
    let shell: String
    var currentCwd: String
    var currentTitle: String = "Terminal"

    // MARK: - Callbacks

    var onClose: (() -> Void)?
    var onMoved: (() -> Void)?
    /// Fired when a drag or resize gesture completes; carries (fromFrame, toFrame).
    var onMoveEnded: ((CGRect, CGRect) -> Void)?
    /// Called during drag with the proposed frame; returns the (possibly snapped) frame.
    var snapFrame: ((CGRect) -> CGRect)?
    var clearSnapGuides: (() -> Void)?
    /// Raw input bytes to broadcast (only fired if broadcast mode is active upstream).
    var onBroadcastKey: ((Data) -> Void)?

    /// Active theme — applied 0.8 s after process start (after shell init sequences).
    var theme: Theme = .dark

    // MARK: - Subviews

    private let titleBar = TitleBarView()
    // nonisolated(unsafe): startProcess is dispatched to a background queue to keep
    // forkpty() off the main thread. SwiftTerm dispatches all post-fork UI callbacks
    // back to the main thread internally.
    private nonisolated(unsafe) var termView: InterceptingTerminalView!
    private var frameBeforeDrag: CGRect = .zero

    // MARK: - Canvas reference (for zoom-corrected drag)

    weak var canvasView: CanvasView?

    /// Plain-text scrollback to re-display on launch (dimmed, before shell prompt).
    var restoredScrollback: String?

    // MARK: - Init

    init(frame: CGRect, shell: String, cwd: String?) {
        self.shell = shell
        self.currentCwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Focus state

    var isActive: Bool = false {
        didSet {
            layer?.borderColor = isActive
                ? NSColor(white: 0.75, alpha: 1).cgColor
                : NSColor(white: 0.25, alpha: 1).cgColor
            layer?.borderWidth = isActive ? 2 : 1
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderColor = NSColor(white: 0.25, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.backgroundColor = Theme.dark.terminalBackground.cgColor

        setupTitleBar()
        setupTerminal()
        setupResizeHandles()
    }

    // MARK: - Title bar

    private func setupTitleBar() {
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleBar)
        NSLayoutConstraint.activate([
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: titleBarHeight),
        ])

        titleBar.onClose = { [weak self] in self?.onClose?() }

        titleBar.onDragBegan = { [weak self] in
            guard let self else { return }
            frameBeforeDrag = frame
        }

        titleBar.onDrag = { [weak self] screenDX, screenDY in
            guard let self, let cv = self.canvasView else { return }
            let zoom = cv.currentZoom
            let proposed = CGRect(x: self.frame.origin.x + screenDX / zoom,
                                  y: self.frame.origin.y - screenDY / zoom,
                                  width: self.frame.width, height: self.frame.height)
            self.frame = self.snapFrame?(proposed) ?? proposed
            self.onMoved?()
        }

        titleBar.onDragEnded = { [weak self] in
            guard let self else { return }
            clearSnapGuides?()
            guard frame != frameBeforeDrag else { return }
            onMoveEnded?(frameBeforeDrag, frame)
        }
    }

    // MARK: - Terminal

    private func setupTerminal() {
        // Frame will be updated in layoutSubviews
        let termFrame = CGRect(x: 0, y: titleBarHeight,
                               width: frame.width, height: frame.height - titleBarHeight)
        termView = InterceptingTerminalView(frame: termFrame)
        termView.translatesAutoresizingMaskIntoConstraints = false
        termView.processDelegate = self
        termView.onSendData = { @Sendable [weak self] data in
            let bytes = Data(data)
            Task { @MainActor [weak self] in
                self?.onBroadcastKey?(bytes)
            }
        }
        termView.nativeForegroundColor = theme.terminalForeground
        termView.nativeBackgroundColor = theme.terminalBackground
        addSubview(termView)

        let p: CGFloat = 8
        NSLayoutConstraint.activate([
            termView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            termView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            termView.topAnchor.constraint(equalTo: topAnchor, constant: titleBarHeight),
            termView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
        ])

        // Force dark appearance so the legacy scroller track renders dark
        // regardless of the system-wide appearance setting.
        termView.appearance = NSAppearance(named: .darkAqua)

        startProcess()
    }

    /// Extract up to `maxLines` of scrollback + visible screen content as plain text.
    func extractScrollbackText(maxLines: Int = 300) -> String {
        let t = termView.terminal!
        var lines: [String] = []

        // Walk backwards through scrollback (negative row indices into getScrollInvariantLine)
        var row = -1
        while lines.count < maxLines {
            guard let line = t.getScrollInvariantLine(row: row) else { break }
            lines.insert(line.translateToString(trimRight: true), at: 0)
            row -= 1
        }

        // Visible screen lines
        for r in 0..<t.rows {
            if let line = t.getScrollInvariantLine(row: r) {
                lines.append(line.translateToString(trimRight: true))
            }
        }

        // Drop trailing blank lines
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\r\n")
    }

    private func startProcess() {
        let settings = TerminalSettings.shared
        applyTerminalSettings(settings)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"

        var isDir: ObjCBool = false
        let cwdExists = FileManager.default.fileExists(atPath: currentCwd, isDirectory: &isDir) && isDir.boolValue
        let cwd = cwdExists ? currentCwd : FileManager.default.homeDirectoryForCurrentUser.path

        let execName = "-" + (shell as NSString).lastPathComponent
        let envList  = env.map { "\($0.key)=\($0.value)" }
        let shellPath = shell
        let scrollbackLines = settings.scrollbackLines
        let cursorStyle = settings.swiftTermCursorStyle

        // Run forkpty on a background thread so the ~2 s atfork-handler cost
        // (libBacktraceRecording) doesn't block the main thread and cause a beachball.
        DispatchQueue.global(qos: .userInitiated).async { [termView] in
            termView!.startProcess(
                executable: shellPath,
                args: [],
                environment: envList,
                execName: execName,
                currentDirectory: cwd
            )
            DispatchQueue.main.async {
                termView!.changeScrollback(scrollbackLines)
                termView!.getTerminal().setCursorStyle(cursorStyle)
            }
        }

        // Apply theme and optionally restore scrollback after shell init sequences have run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.applyTheme(self.theme)
            if let text = self.restoredScrollback, !text.isEmpty {
                self.restoredScrollback = nil
                // Strip all ANSI/OSC escape sequences from the persisted scrollback
                // before re-feeding it. Without this, a tampered workspace.json could
                // inject OSC sequences (e.g. OSC 8 hyperlinks, OSC 1337 file transfers,
                // title-setting sequences) into the running terminal.
                let safe = TerminalWindowView.stripEscapeSequences(text)
                // Dim color + italic, then show saved content, then reset
                let dimmed = "\u{1B}[2;3m" + safe + "\u{1B}[0m\r\n"
                self.termView.feed(text: dimmed)
            }
        }
    }

    /// Remove ANSI CSI sequences (`ESC [ … m/A/B/…`), OSC sequences
    /// (`ESC ] … BEL/ST`), and bare `ESC X` two-character sequences from `text`.
    /// Used to sanitise persisted scrollback before re-feeding it to the terminal.
    static func stripEscapeSequences(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iter = text.unicodeScalars.makeIterator()
        while let ch = iter.next() {
            guard ch == "\u{1B}" else { result.unicodeScalars.append(ch); continue }
            // Peek at the next character to classify the sequence type.
            guard let next = iter.next() else { break }
            switch next {
            case "[":
                // CSI: consume until a byte in 0x40–0x7E (the final byte)
                while let c = iter.next() {
                    if c.value >= 0x40 && c.value <= 0x7E { break }
                }
            case "]":
                // OSC: consume until BEL (0x07) or ST (ESC \)
                var prev: Unicode.Scalar = "\u{00}"
                while let c = iter.next() {
                    if c == "\u{07}" { break }
                    if prev == "\u{1B}" && c == "\\" { break }
                    prev = c
                }
            default:
                // Two-character escape sequence — already consumed `next`; discard it.
                break
            }
        }
        return result
    }

    func applyTerminalSettings(_ settings: TerminalSettings) {
        termView.optionAsMetaKey        = settings.optionAsMetaKey
        termView.backspaceSendsControlH = settings.backspaceSendsControlH
        termView.allowMouseReporting    = settings.allowMouseReporting
        termView.useBrightColors        = settings.useBrightColors
        termView.changeScrollback(settings.scrollbackLines)
        termView.getTerminal().setCursorStyle(settings.swiftTermCursorStyle)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        termView.nativeForegroundColor = theme.terminalForeground
        termView.nativeBackgroundColor = theme.terminalBackground
        termView.font = theme.terminalFont
        termView.feed(text: theme.oscSequences)
        layer?.backgroundColor = theme.terminalBackground.cgColor
        titleBar.applyTheme(background: theme.terminalBackground, foreground: theme.terminalForeground)
    }

    private func syncTitleBarColor() {
        titleBar.applyTheme(background: theme.terminalBackground, foreground: theme.terminalForeground)
    }

    // MARK: - Resize handles

    private func setupResizeHandles() {
        for edge in ResizeHandleView.Edge.allCases {
            let h = ResizeHandleView(edge: edge)
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
            h.installConstraints(in: self)
            h.onResizeBegan = { [weak self] in
                guard let self else { return }
                frameBeforeDrag = frame
            }
            h.onResize = { [weak self] dx, dy in
                self?.handleResize(edge: edge, screenDX: dx, screenDY: dy)
            }
            h.onResizeEnded = { [weak self] in
                guard let self else { return }
                clearSnapGuides?()
                guard frame != frameBeforeDrag else { return }
                onMoveEnded?(frameBeforeDrag, frame)
            }
        }
    }

    private func handleResize(edge: ResizeHandleView.Edge, screenDX: CGFloat, screenDY: CGFloat) {
        guard let cv = canvasView else { return }
        let zoom = cv.currentZoom
        let dx = screenDX / zoom
        // screenDY is window-space y-up; world space is y-down, so negate
        let dy = -screenDY / zoom

        var r = frame
        switch edge {
        case .topLeft:
            r.origin.x += dx; r.size.width -= dx
            r.origin.y += dy; r.size.height -= dy
        case .top:
            r.origin.y += dy; r.size.height -= dy
        case .topRight:
            r.size.width += dx
            r.origin.y += dy; r.size.height -= dy
        case .left:
            r.origin.x += dx; r.size.width -= dx
        case .right:
            r.size.width += dx
        case .bottomLeft:
            r.origin.x += dx; r.size.width -= dx
            r.size.height += dy
        case .bottom:
            r.size.height += dy
        case .bottomRight:
            r.size.width += dx
            r.size.height += dy
        }

        r.size.width  = max(r.size.width,  minSize.width)
        r.size.height = max(r.size.height, minSize.height)

        // Apply edge-aware snapping: call snapFrame to find alignment deltas, then
        // apply each delta to the dimension that's actually moving for this edge.
        if let snap = snapFrame {
            let snapped = snap(r)
            let sdx = snapped.origin.x - r.origin.x
            let sdy = snapped.origin.y - r.origin.y

            let dragsRight  = edge == .right  || edge == .topRight    || edge == .bottomRight
            let dragsLeft   = edge == .left   || edge == .topLeft     || edge == .bottomLeft
            let dragsBottom = edge == .bottom || edge == .bottomLeft  || edge == .bottomRight
            let dragsTop    = edge == .top    || edge == .topLeft     || edge == .topRight

            if dragsRight       { r.size.width  += sdx }
            else if dragsLeft   { r.origin.x    += sdx; r.size.width  -= sdx }
            if dragsBottom      { r.size.height += sdy }
            else if dragsTop    { r.origin.y    += sdy; r.size.height -= sdy }

            r.size.width  = max(r.size.width,  minSize.width)
            r.size.height = max(r.size.height, minSize.height)
        }

        frame = r
        onMoved?()
    }

    // MARK: - Focus

    func focusTerminal() {
        window?.makeFirstResponder(termView)
    }

    // MARK: - Input broadcasting

    func sendInput(_ data: Data) {
        let bytes = [UInt8](data)
        termView.suppressBroadcast = true
        termView.send(data: bytes[...])
        termView.suppressBroadcast = false
    }

    // MARK: - Visual state

    func setBroadcastHighlight(_ on: Bool) {
        if on {
            titleBar.layer?.backgroundColor = NSColor(red: 0.15, green: 0.3, blue: 0.15, alpha: 1).cgColor
        } else {
            syncTitleBarColor()
        }
    }

    func terminate() {
        // SwiftTerm tears down the PTY when the view is deallocated,
        // but we can signal the process to exit cleanly.
        termView.send(data: [0x04][...])  // Ctrl-D / EOF
    }
}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalWindowView: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SIGWINCH is sent automatically by SwiftTerm; nothing extra needed here
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.currentTitle = title
            self?.titleBar.titleLabel.stringValue = title
            self?.syncTitleBarColor()
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let dir = directory else { return }
        // SwiftTerm passes a file:// URL; extract the plain POSIX path.
        let path = URL(string: dir)?.path ?? dir
        Task { @MainActor [weak self] in
            self?.currentCwd = path
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.onClose?()
        }
    }
}

