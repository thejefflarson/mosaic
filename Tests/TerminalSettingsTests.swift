import Testing
import Foundation
@testable import Mosaic

struct TerminalSettingsTests {

    // MARK: - Default values

    @Test func defaultCursorStyle() {
        #expect(TerminalSettings().cursorStyle == .blinkBlock)
    }

    @Test func defaultScrollbackLines() {
        #expect(TerminalSettings().scrollbackLines == 500)
    }

    @Test func defaultOptionAsMetaKey() {
        #expect(TerminalSettings().optionAsMetaKey == true)
    }

    @Test func defaultBackspaceSendsControlH() {
        #expect(TerminalSettings().backspaceSendsControlH == false)
    }

    @Test func defaultAllowMouseReporting() {
        #expect(TerminalSettings().allowMouseReporting == true)
    }

    @Test func defaultUseBrightColors() {
        #expect(TerminalSettings().useBrightColors == true)
    }

    // MARK: - JSON round-trip

    @Test func jsonRoundTripPreservesAllFields() throws {
        var s = TerminalSettings()
        s.cursorStyle            = .steadyBar
        s.scrollbackLines        = 2000
        s.optionAsMetaKey        = false
        s.backspaceSendsControlH = true
        s.allowMouseReporting    = false
        s.useBrightColors        = false

        let decoded = try JSONDecoder().decode(
            TerminalSettings.self, from: JSONEncoder().encode(s))

        #expect(decoded.cursorStyle            == .steadyBar)
        #expect(decoded.scrollbackLines        == 2000)
        #expect(decoded.optionAsMetaKey        == false)
        #expect(decoded.backspaceSendsControlH == true)
        #expect(decoded.allowMouseReporting    == false)
        #expect(decoded.useBrightColors        == false)
    }

    @Test func jsonRoundTripDefaultValues() throws {
        let decoded = try JSONDecoder().decode(
            TerminalSettings.self, from: JSONEncoder().encode(TerminalSettings()))
        #expect(decoded.cursorStyle     == .blinkBlock)
        #expect(decoded.scrollbackLines == 500)
        #expect(decoded.optionAsMetaKey == true)
    }

    // MARK: - UserDefaults round-trip

    @Test func userDefaultsRoundTrip() {
        let saved = TerminalSettings.shared   // preserve whatever is stored
        defer { TerminalSettings.shared = saved }

        var custom = TerminalSettings()
        custom.scrollbackLines = 1500
        custom.cursorStyle     = .blinkUnderline
        custom.optionAsMetaKey = false
        TerminalSettings.shared = custom

        let loaded = TerminalSettings.shared
        #expect(loaded.scrollbackLines == 1500)
        #expect(loaded.cursorStyle     == .blinkUnderline)
        #expect(loaded.optionAsMetaKey == false)
    }

    @Test func userDefaultsReturnsDefaultWhenKeyAbsent() {
        let saved = UserDefaults.standard.data(forKey: "terminalSettings")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "terminalSettings") }
            else { UserDefaults.standard.removeObject(forKey: "terminalSettings") }
        }
        UserDefaults.standard.removeObject(forKey: "terminalSettings")
        let s = TerminalSettings.shared
        #expect(s.cursorStyle     == .blinkBlock)
        #expect(s.scrollbackLines == 500)
    }

    // MARK: - StoredCursorStyle

    @Test(arguments: TerminalSettings.StoredCursorStyle.allCases)
    func cursorStyleHasNonEmptyDisplayName(_ style: TerminalSettings.StoredCursorStyle) {
        #expect(!style.displayName.isEmpty)
    }

    @Test(arguments: TerminalSettings.StoredCursorStyle.allCases)
    func cursorStyleJsonRoundTrip(_ style: TerminalSettings.StoredCursorStyle) throws {
        let decoded = try JSONDecoder().decode(
            TerminalSettings.StoredCursorStyle.self,
            from: JSONEncoder().encode(style))
        #expect(decoded == style)
    }

    /// Each StoredCursorStyle must map to a SwiftTerm CursorStyle without crashing.
    @Test(arguments: TerminalSettings.StoredCursorStyle.allCases)
    func cursorStyleSwiftTermMappingDoesNotCrash(_ style: TerminalSettings.StoredCursorStyle) {
        _ = style.swiftTermStyle
    }

    @Test func allCursorStylesAreCovered() {
        // Guard against a new case being added without a display name.
        #expect(TerminalSettings.StoredCursorStyle.allCases.count == 6)
    }
}
