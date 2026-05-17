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

    @Test func osc133PromptAndCommandMarkers() {
        #expect(InterceptingTerminalView.parseOSC133("A") == .promptStart)
        #expect(InterceptingTerminalView.parseOSC133("B") == .commandStart)
    }

    @Test func osc133IgnoresUnknownAndEmpty() {
        // C (command executed) isn't actionable for us — unparsed.
        #expect(InterceptingTerminalView.parseOSC133("C") == nil)
        #expect(InterceptingTerminalView.parseOSC133("") == nil)
        #expect(InterceptingTerminalView.parseOSC133("X") == nil)
    }

    // MARK: - sanitizeNotificationText
    //
    // OSC 777 payloads come from terminal output; before reaching
    // UNUserNotificationCenter they're clamped and stripped of control bytes.

    @Test func sanitizeClampsToMaxLength() {
        let long = String(repeating: "x", count: 1000)
        #expect(InterceptingTerminalView.sanitizeNotificationText(long, max: 16).count == 16)
    }

    @Test func sanitizeStripsC0Controls() {
        // Bell, backspace, form feed — all stripped. Newline is preserved.
        let s = "hi\u{07}\u{08}\u{0C}\nworld"
        #expect(InterceptingTerminalView.sanitizeNotificationText(s, max: 100) == "hi\nworld")
    }

    @Test func sanitizeStripsC1Controls() {
        // 8-bit C1 introducers (0x80..0x9F) all removed.
        let s = "before\u{9B}31mafter\u{9D}link\u{07}"
        let cleaned = InterceptingTerminalView.sanitizeNotificationText(s, max: 100)
        for v: UInt32 in 0x80...0x9F {
            #expect(!cleaned.unicodeScalars.contains(Unicode.Scalar(v)!),
                    "C1 byte U+\(String(v, radix: 16)) leaked through")
        }
    }

    @Test func sanitizeKeepsPrintableUnicode() {
        let s = "Build ✓ — passed (≈3s)"
        #expect(InterceptingTerminalView.sanitizeNotificationText(s, max: 100) == s)
    }

    // MARK: - stripEscapeSequences (broader coverage)
    //
    // The existing LinkResolutionTests cover C1 introducers; below covers the
    // 7-bit ESC paths and mixed payloads.

    @Test func stripsCSI() {
        #expect(TerminalWindowView.stripEscapeSequences("a\u{1B}[31mb\u{1B}[0mc") == "abc")
    }

    @Test func stripsOSCBEL() {
        // OSC 8 hyperlink terminated by BEL.
        let s = "before\u{1B}]8;;https://x\u{07}label\u{1B}]8;;\u{07}after"
        #expect(TerminalWindowView.stripEscapeSequences(s) == "beforelabelafter")
    }

    @Test func stripsOSCST() {
        // OSC terminated by ST (ESC \).
        let s = "before\u{1B}]0;title\u{1B}\\after"
        #expect(TerminalWindowView.stripEscapeSequences(s) == "beforeafter")
    }

    @Test func stripsDCSAndPM() {
        let dcs = "a\u{1B}Pdata\u{1B}\\b"
        let pm  = "c\u{1B}^secret\u{1B}\\d"
        let apc = "e\u{1B}_app\u{1B}\\f"
        #expect(TerminalWindowView.stripEscapeSequences(dcs) == "ab")
        #expect(TerminalWindowView.stripEscapeSequences(pm)  == "cd")
        #expect(TerminalWindowView.stripEscapeSequences(apc) == "ef")
    }

    @Test func stripsTwoByteEsc() {
        // Plain ESC X (e.g. ESC =, ESC >, ESC c) — drop both bytes.
        #expect(TerminalWindowView.stripEscapeSequences("a\u{1B}=b") == "ab")
        #expect(TerminalWindowView.stripEscapeSequences("a\u{1B}>b") == "ab")
    }

    @Test func preservesPlainText() {
        let s = "no escapes here — just text 🚀"
        #expect(TerminalWindowView.stripEscapeSequences(s) == s)
    }
}
