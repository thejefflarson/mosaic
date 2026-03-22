import XCTest
@testable import Mosaic

final class ThemeEditorTests: XCTestCase {

    // MARK: - buildPreviewTheme

    func testBuildPreviewThemePreservesSourceID() {
        let model = ThemeEditorModel(theme: Theme.dark)
        let preview = model.buildPreviewTheme()
        XCTAssertEqual(preview.id, Theme.dark.id)
    }

    func testBuildPreviewThemePreservesSourceIDForCustomTheme() {
        let custom = Theme(id: "my-theme", name: "My Theme",
                           canvasBackground: .black, terminalBackground: .black,
                           terminalForeground: .white, ansi: Theme.dark.ansi)
        let model = ThemeEditorModel(theme: custom)
        XCTAssertEqual(model.buildPreviewTheme().id, "my-theme")
    }

    func testBuildPreviewThemeIsStableAcrossMultipleCalls() {
        let model = ThemeEditorModel(theme: Theme.oneDark)
        let id1 = model.buildPreviewTheme().id
        let id2 = model.buildPreviewTheme().id
        XCTAssertEqual(id1, id2)
    }

    // MARK: - buildNewTheme

    func testBuildNewThemeHasFreshUUID() {
        let model = ThemeEditorModel(theme: Theme.dark)
        let t = model.buildNewTheme()
        // Must be a valid UUID string
        XCTAssertNotNil(UUID(uuidString: t.id))
    }

    func testBuildNewThemeIDDiffersFromSourceID() {
        let model = ThemeEditorModel(theme: Theme.dark)
        XCTAssertNotEqual(model.buildNewTheme().id, Theme.dark.id)
    }

    func testBuildNewThemeProducesUniqueIDsEachCall() {
        let model = ThemeEditorModel(theme: Theme.dark)
        let id1 = model.buildNewTheme().id
        let id2 = model.buildNewTheme().id
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - Name handling

    func testEmptyNameDefaultsToCustom() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.name = ""
        XCTAssertEqual(model.buildPreviewTheme().name, "Custom")
    }

    func testWhitespaceOnlyNameDefaultsToCustom() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.name = "   "
        XCTAssertEqual(model.buildPreviewTheme().name, "Custom")
    }

    func testNameIsTrimed() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.name = "  My Theme  "
        XCTAssertEqual(model.buildPreviewTheme().name, "My Theme")
    }

    func testNonEmptyNameIsPreserved() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.name = "Dracula"
        XCTAssertEqual(model.buildPreviewTheme().name, "Dracula")
    }

    // MARK: - Font size parsing

    func testValidFontSizeParsed() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.termFontSize = "16"
        XCTAssertEqual(model.buildPreviewTheme().fontSize, 16)
    }

    func testInvalidFontSizeFallsBackToDefault() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.termFontSize = "not-a-number"
        // buildTheme falls back to 13 for terminal font
        XCTAssertEqual(model.buildPreviewTheme().fontSize, 13)
    }

    func testInvalidAnnotationFontSizeFallsBackToDefault() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.annotFontSize = "bad"
        // buildTheme falls back to 148 for annotation font
        XCTAssertEqual(model.buildPreviewTheme().annotationFontSize, 148)
    }

    func testAnnotationFontSizeParsed() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.annotFontSize = "72"
        XCTAssertEqual(model.buildPreviewTheme().annotationFontSize, 72)
    }

    // MARK: - populate(from:) updates sourceID

    func testPopulateFromUpdatesSourceID() {
        let model = ThemeEditorModel(theme: Theme.dark)
        XCTAssertEqual(model.buildPreviewTheme().id, Theme.dark.id)

        model.populate(from: Theme.solarizedDark)
        XCTAssertEqual(model.buildPreviewTheme().id, Theme.solarizedDark.id)
    }

    func testPopulateFromUpdatesName() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.populate(from: Theme.gruvboxDark)
        XCTAssertEqual(model.name, Theme.gruvboxDark.name)
    }

    // MARK: - Color round-trip through model

    func testCanvasBackgroundRoundTrip() {
        let model = ThemeEditorModel(theme: Theme.dark)
        let original = Theme.dark.canvasBackground
        let built = model.buildPreviewTheme().canvasBackground
        XCTAssertEqual(built.hex, original.hex)
    }

    func testTerminalBackgroundRoundTrip() {
        let model = ThemeEditorModel(theme: Theme.oneDark)
        XCTAssertEqual(model.buildPreviewTheme().terminalBackground.hex,
                       Theme.oneDark.terminalBackground.hex)
    }

    func testAnsiColorsRoundTrip() {
        let model = ThemeEditorModel(theme: Theme.dark)
        let built = model.buildPreviewTheme()
        XCTAssertEqual(built.ansi.count, 16)
        for i in 0..<16 {
            XCTAssertEqual(built.ansi[i].hex, Theme.dark.ansi[i].hex,
                           "ANSI color \(i) should survive model round-trip")
        }
    }

    // MARK: - Auto-save integration (onApply)

    func testOnApplyFiredWhenModelChanges() {
        let model = ThemeEditorModel(theme: Theme.dark)
        var appliedCount = 0
        model.onApply = { _ in appliedCount += 1 }

        // Simulate what the SwiftUI view does on objectWillChange
        model.name = "Changed"
        model.onApply?(model.buildPreviewTheme())
        XCTAssertEqual(appliedCount, 1)
    }

    func testOnApplyThemeHasCorrectID() {
        let model = ThemeEditorModel(theme: Theme.solarizedDark)
        var receivedID: String?
        model.onApply = { receivedID = $0.id }

        model.onApply?(model.buildPreviewTheme())
        XCTAssertEqual(receivedID, Theme.solarizedDark.id)
    }

    func testOnSaveThemeHasFreshID() {
        let model = ThemeEditorModel(theme: Theme.dark)
        var receivedID: String?
        model.onSave = { receivedID = $0.id }

        model.onSave?(model.buildNewTheme())
        XCTAssertNotNil(receivedID)
        XCTAssertNotEqual(receivedID, Theme.dark.id)
    }

    // MARK: - displayName helper

    func testDisplayNameForEmptyFamilyMonospace() {
        XCTAssertEqual(ThemeEditorModel.displayName(forFamily: "", isMonospace: true),
                       "System Monospaced")
    }

    func testDisplayNameForEmptyFamilyNonMonospace() {
        XCTAssertEqual(ThemeEditorModel.displayName(forFamily: "", isMonospace: false),
                       "System Font")
    }

    func testDisplayNameForNamedFamily() {
        XCTAssertEqual(ThemeEditorModel.displayName(forFamily: "Helvetica", isMonospace: false),
                       "Helvetica")
    }
}
