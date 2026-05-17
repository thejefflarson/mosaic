import AppKit

/// Lightweight in-terminal find bar. SwiftTerm's built-in find UI conflicts with
/// our world-space layout (it beachballs on Cmd+F), so we drive its public
/// findNext/findPrevious API ourselves with this minimal control.
@MainActor
final class TerminalFindBar: NSVisualEffectView, NSSearchFieldDelegate {
    var onSearchChanged: ((String) -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let searchField = NSSearchField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    var searchText: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    /// Update the "n of m" indicator. Pass total=0 for no matches, current=0 to hide.
    func setMatchInfo(current: Int, total: Int) {
        if searchField.stringValue.isEmpty {
            matchLabel.stringValue = ""
        } else if total == 0 {
            matchLabel.stringValue = "No results"
        } else {
            matchLabel.stringValue = "\(current) of \(total)"
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(searchField) }

    private func setup() {
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(prevButton, symbol: "chevron.up", action: #selector(prevTapped), tooltip: "Previous (⇧⏎)")
        configure(nextButton, symbol: "chevron.down", action: #selector(nextTapped), tooltip: "Next (⏎)")
        configure(closeButton, symbol: "xmark", action: #selector(closeTapped), tooltip: "Close (⎋)")

        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.alignment = .right
        matchLabel.setContentHuggingPriority(.required, for: .horizontal)
        matchLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [searchField, matchLabel, prevButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector, tooltip: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.controlSize = .small
        button.target = self
        button.action = action
        button.toolTip = tooltip
    }

    @objc private func searchSubmitted() {
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            onFindPrevious?()
        } else {
            onFindNext?()
        }
    }

    @objc private func prevTapped() { onFindPrevious?() }
    @objc private func nextTapped() { onFindNext?() }
    @objc private func closeTapped() { onClose?() }

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchSubmitted()
            return true
        }
        return false
    }
}
