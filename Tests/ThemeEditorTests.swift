import Testing
import AppKit
@testable import Mosaic

struct ThemeEditorTests {

    // MARK: - buildPreviewTheme

    @Test func buildPreviewThemePreservesSourceID() {
        #expect(ThemeEditorModel(theme: Theme.dark).buildPreviewTheme().id == Theme.dark.id)
    }

    @Test func buildPreviewThemePreservesSourceIDForCustomTheme() {
        let custom = Theme(id: "my-theme", name: "My Theme",
                           canvasBackground: .black, terminalBackground: .black,
                           terminalForeground: .white, ansi: Theme.dark.ansi)
        #expect(ThemeEditorModel(theme: custom).buildPreviewTheme().id == "my-theme")
    }

    @Test func buildPreviewThemeIsStableAcrossMultipleCalls() {
        let model = ThemeEditorModel(theme: Theme.oneDark)
        #expect(model.buildPreviewTheme().id == model.buildPreviewTheme().id)
    }

    // MARK: - buildNewTheme

    @Test func buildNewThemeHasFreshUUID() {
        let t = ThemeEditorModel(theme: Theme.dark).buildNewTheme()
        #expect(UUID(uuidString: t.id) != nil)
    }

    @Test func buildNewThemeIDDiffersFromSourceID() {
        #expect(ThemeEditorModel(theme: Theme.dark).buildNewTheme().id != Theme.dark.id)
    }

    @Test func buildNewThemeProducesUniqueIDsEachCall() {
        let model = ThemeEditorModel(theme: Theme.dark)
        #expect(model.buildNewTheme().id != model.buildNewTheme().id)
    }

    // MARK: - Name handling

    @Test func emptyNameDefaultsToCustom() {
        let model = ThemeEditorModel(theme: Theme.dark); model.name = ""
        #expect(model.buildPreviewTheme().name == "Custom")
    }

    @Test func whitespaceOnlyNameDefaultsToCustom() {
        let model = ThemeEditorModel(theme: Theme.dark); model.name = "   "
        #expect(model.buildPreviewTheme().name == "Custom")
    }

    @Test func nameIsTrimmed() {
        let model = ThemeEditorModel(theme: Theme.dark); model.name = "  My Theme  "
        #expect(model.buildPreviewTheme().name == "My Theme")
    }

    @Test func nonEmptyNameIsPreserved() {
        let model = ThemeEditorModel(theme: Theme.dark); model.name = "Dracula"
        #expect(model.buildPreviewTheme().name == "Dracula")
    }

    // MARK: - Font size parsing

    @Test func validFontSizeParsed() {
        let model = ThemeEditorModel(theme: Theme.dark); model.termFontSize = "16"
        #expect(model.buildPreviewTheme().fontSize == 16)
    }

    @Test func invalidFontSizeFallsBackToDefault() {
        let model = ThemeEditorModel(theme: Theme.dark); model.termFontSize = "not-a-number"
        #expect(model.buildPreviewTheme().fontSize == 13)
    }

    @Test func invalidAnnotationFontSizeFallsBackToDefault() {
        let model = ThemeEditorModel(theme: Theme.dark); model.annotFontSize = "bad"
        #expect(model.buildPreviewTheme().annotationFontSize == 148)
    }

    @Test func annotationFontSizeParsed() {
        let model = ThemeEditorModel(theme: Theme.dark); model.annotFontSize = "72"
        #expect(model.buildPreviewTheme().annotationFontSize == 72)
    }

    // MARK: - populate(from:) updates sourceID

    @Test func populateFromUpdatesSourceID() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.populate(from: Theme.solarizedDark)
        #expect(model.buildPreviewTheme().id == Theme.solarizedDark.id)
    }

    @Test func populateFromUpdatesName() {
        let model = ThemeEditorModel(theme: Theme.dark)
        model.populate(from: Theme.gruvboxDark)
        #expect(model.name == Theme.gruvboxDark.name)
    }

    // MARK: - Color round-trip through model

    @Test func canvasBackgroundRoundTrip() {
        let model = ThemeEditorModel(theme: Theme.dark)
        #expect(model.buildPreviewTheme().canvasBackground.hex == Theme.dark.canvasBackground.hex)
    }

    @Test func terminalBackgroundRoundTrip() {
        let model = ThemeEditorModel(theme: Theme.oneDark)
        #expect(model.buildPreviewTheme().terminalBackground.hex == Theme.oneDark.terminalBackground.hex)
    }

    @Test func ansiColorsRoundTrip() {
        let built = ThemeEditorModel(theme: Theme.dark).buildPreviewTheme()
        #expect(built.ansi.count == 16)
        for i in 0..<16 {
            #expect(built.ansi[i].hex == Theme.dark.ansi[i].hex,
                    "ANSI color \(i) should survive model round-trip")
        }
    }

    // MARK: - onApply / onSave callbacks

    @Test func onApplyFiredWhenModelChanges() {
        let model = ThemeEditorModel(theme: Theme.dark)
        var count = 0
        model.onApply = { _ in count += 1 }
        model.name = "Changed"
        model.onApply?(model.buildPreviewTheme())
        #expect(count == 1)
    }

    @Test func onApplyThemeHasCorrectID() {
        let model = ThemeEditorModel(theme: Theme.solarizedDark)
        var receivedID: String?
        model.onApply = { receivedID = $0.id }
        model.onApply?(model.buildPreviewTheme())
        #expect(receivedID == Theme.solarizedDark.id)
    }

    @Test func onSaveThemeHasFreshID() {
        let model = ThemeEditorModel(theme: Theme.dark)
        var receivedID: String?
        model.onSave = { receivedID = $0.id }
        model.onSave?(model.buildNewTheme())
        #expect(receivedID != nil)
        #expect(receivedID != Theme.dark.id)
    }

    // MARK: - displayName helper

    @Test func displayNameForEmptyFamilyMonospace() {
        #expect(ThemeEditorModel.displayName(forFamily: "", isMonospace: true) == "System Monospaced")
    }

    @Test func displayNameForEmptyFamilyNonMonospace() {
        #expect(ThemeEditorModel.displayName(forFamily: "", isMonospace: false) == "System Font")
    }

    @Test func displayNameForNamedFamily() {
        #expect(ThemeEditorModel.displayName(forFamily: "Helvetica", isMonospace: false) == "Helvetica")
    }
}
