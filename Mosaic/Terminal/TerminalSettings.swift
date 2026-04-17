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
