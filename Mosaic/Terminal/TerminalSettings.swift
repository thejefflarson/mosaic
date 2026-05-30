import Foundation
import SwiftTerm

/// Global terminal behaviour settings, stored in UserDefaults.
/// These are separate from Theme (appearance) — they control how the terminal
/// interprets input and manages its buffer.
struct TerminalSettings: Codable {
    /// Cursor shape for new terminal windows.
    var cursorStyle: StoredCursorStyle = .blinkBlock
    /// Scrollback buffer size for new terminal windows.
    var scrollbackLines: Int = 500
    /// Whether the ⌥ (Option) key sends an ESC prefix (Meta behaviour).
    var optionAsMetaKey: Bool = true
    /// If true, backspace sends ^H instead of ^? (DEL). Most modern systems want ^?.
    var backspaceSendsControlH: Bool = false
    /// Allow terminal applications to receive mouse events.
    var allowMouseReporting: Bool = true
    /// Use bright ANSI colours for bold text instead of rendering bold weight.
    var useBrightColors: Bool = true
    /// Pan the canvas to a terminal when it emits a bell or notification.
    var panOnBell: Bool = false
    /// Flash the terminal border on bell / notification.
    var flashOnBell: Bool = true
    /// Persist scrollback into workspace.json so it can be replayed on next
    /// launch. Off by default: scrollback frequently contains pasted secrets
    /// (.env exports, AWS keys, `gh auth login` tokens) and workspace.json
    /// leaks through Time Machine / iCloud Drive of Application Support /
    /// `tar` of the home directory.
    var persistScrollback: Bool = false

    init() {}

    // Forward-compatible decoding: settings blobs written by older builds won't
    // have keys for newly-added fields. Synthesized Codable requires every key,
    // so a single missing field would discard the whole stored blob and make
    // all settings look like they don't persist. Decode each key optionally
    // and fall through to the property's default value.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cursorStyle            = try c.decodeIfPresent(StoredCursorStyle.self, forKey: .cursorStyle)            ?? self.cursorStyle
        // Clamp scrollback to a sane range — UserDefaults is shared with any process
        // running as the user, so an Int.max in the stored blob would otherwise be
        // forwarded to SwiftTerm's buffer allocator on every new terminal.
        let raw = try c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? self.scrollbackLines
        self.scrollbackLines        = min(max(raw, 0), 100_000)
        self.optionAsMetaKey        = try c.decodeIfPresent(Bool.self,             forKey: .optionAsMetaKey)        ?? self.optionAsMetaKey
        self.backspaceSendsControlH = try c.decodeIfPresent(Bool.self,             forKey: .backspaceSendsControlH) ?? self.backspaceSendsControlH
        self.allowMouseReporting    = try c.decodeIfPresent(Bool.self,             forKey: .allowMouseReporting)    ?? self.allowMouseReporting
        self.useBrightColors        = try c.decodeIfPresent(Bool.self,             forKey: .useBrightColors)        ?? self.useBrightColors
        self.panOnBell              = try c.decodeIfPresent(Bool.self,             forKey: .panOnBell)              ?? self.panOnBell
        self.flashOnBell            = try c.decodeIfPresent(Bool.self,             forKey: .flashOnBell)            ?? self.flashOnBell
        self.persistScrollback      = try c.decodeIfPresent(Bool.self,             forKey: .persistScrollback)      ?? self.persistScrollback
    }

    // MARK: - Persistence

    static var shared: TerminalSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "terminalSettings"),
                  let s = try? JSONDecoder().decode(TerminalSettings.self, from: data)
            else { return TerminalSettings() }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "terminalSettings")
            }
        }
    }

    // MARK: - SwiftTerm conversions

    var swiftTermCursorStyle: CursorStyle { cursorStyle.swiftTermStyle }

    /// CursorStyle is not Codable in SwiftTerm, so we mirror it.
    enum StoredCursorStyle: String, Codable, CaseIterable {
        case blinkBlock, steadyBlock
        case blinkUnderline, steadyUnderline
        case blinkBar, steadyBar

        var displayName: String {
            switch self {
            case .blinkBlock:      return "Block (blinking)"
            case .steadyBlock:     return "Block (steady)"
            case .blinkUnderline:  return "Underline (blinking)"
            case .steadyUnderline: return "Underline (steady)"
            case .blinkBar:        return "Bar (blinking)"
            case .steadyBar:       return "Bar (steady)"
            }
        }

        var swiftTermStyle: CursorStyle {
            switch self {
            case .blinkBlock:      return .blinkBlock
            case .steadyBlock:     return .steadyBlock
            case .blinkUnderline:  return .blinkUnderline
            case .steadyUnderline: return .steadyUnderline
            case .blinkBar:        return .blinkBar
            case .steadyBar:       return .steadyBar
            }
        }
    }
}
