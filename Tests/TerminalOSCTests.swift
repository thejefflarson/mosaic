import Testing
@testable import Mosaic

@MainActor
struct TerminalOSCTests {

    // MARK: - Copy trim

    @Test func trimStripsTrailingSpacesFromEachLine() {
        let input = "hello   \nworld  \n"
        #expect(InterceptingTerminalView.trimTrailingSpacesPerLine(input) == "hello\nworld\n")
    }

    @Test func trimPreservesInteriorSpaces() {
        #expect(InterceptingTerminalView.trimTrailingSpacesPerLine("a b c   ") == "a b c")
    }

    @Test func trimHandlesCarriageReturns() {
        // \r is separate from \n; trim per \r-delimited segment too.
        let input = "foo   \r\nbar  "
        #expect(InterceptingTerminalView.trimTrailingSpacesPerLine(input) == "foo\r\nbar")
    }

    @Test func trimEmptyAndWhitespaceOnly() {
        #expect(InterceptingTerminalView.trimTrailingSpacesPerLine("") == "")
        #expect(InterceptingTerminalView.trimTrailingSpacesPerLine("   ") == "")
        #expect(InterceptingTerminalView.trimTrailingSpacesPerLine("   \n   ") == "\n")
    }

    @Test func trimPreservesLineStructure() {
        // Three lines, two blank → two newlines preserved.
        let input = "line1 \n\nline3 "
        #expect(InterceptingTerminalView.trimTrailingSpacesPerLine(input) == "line1\n\nline3")
    }

    // MARK: - OSC 777

    @Test func osc777ParsesTitleAndBody() {
        let r = InterceptingTerminalView.parseOSC777("notify;My Title;My Body")
        #expect(r?.title == "My Title")
        #expect(r?.body == "My Body")
    }

    @Test func osc777AllowsSemicolonsInBody() {
        // maxSplits=2 means the body keeps any extra ';' intact.
        let r = InterceptingTerminalView.parseOSC777("notify;Title;body; with; semis")
        #expect(r?.title == "Title")
        #expect(r?.body == "body; with; semis")
    }

    @Test func osc777TitleOnlyHasEmptyBody() {
        let r = InterceptingTerminalView.parseOSC777("notify;OnlyTitle")
        #expect(r?.title == "OnlyTitle")
        #expect(r?.body == "")
    }

    @Test func osc777RejectsNonNotifyVerb() {
        #expect(InterceptingTerminalView.parseOSC777("other;Title;Body") == nil)
        #expect(InterceptingTerminalView.parseOSC777("") == nil)
        #expect(InterceptingTerminalView.parseOSC777("notify") == nil)
    }

    // MARK: - OSC 133

    @Test func osc133DWithExitCode() {
        #expect(InterceptingTerminalView.parseOSC133("D;0") == .commandFinished(exitCode: 0))
        #expect(InterceptingTerminalView.parseOSC133("D;1") == .commandFinished(exitCode: 1))
        #expect(InterceptingTerminalView.parseOSC133("D;127") == .commandFinished(exitCode: 127))
    }

    @Test func osc133DWithoutExitCode() {
        #expect(InterceptingTerminalView.parseOSC133("D") == .commandFinished(exitCode: nil))
    }

    @Test func osc133DWithNonNumericExitIsNil() {
        #expect(InterceptingTerminalView.parseOSC133("D;abc") == .commandFinished(exitCode: nil))
    }

    @Test func osc133IgnoresOtherMarkers() {
        #expect(InterceptingTerminalView.parseOSC133("A") == nil)
        #expect(InterceptingTerminalView.parseOSC133("B") == nil)
        #expect(InterceptingTerminalView.parseOSC133("C") == nil)
        #expect(InterceptingTerminalView.parseOSC133("") == nil)
    }
}
