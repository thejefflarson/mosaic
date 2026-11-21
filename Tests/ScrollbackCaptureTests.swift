import Foundation
import Testing
@testable import Mosaic

/// The SwiftTerm v2 migration re-pointed scrollback capture and find-bar match
/// counting at the public `getBufferAsData` (the mutable `Terminal` and
/// `getScrollInvariantLine` are gone). The per-line/per-buffer capping and the
/// CRLF-safe row split were factored into pure static helpers so they can be
/// checked here without a PTY; the view-level `getBufferAsData` plumbing is covered
/// by the runtime-test checklist (scrollback copy, find/search).
struct ScrollbackCaptureTests {

    // MARK: - bufferRows (CRLF-safe split + right-trim)

    @Test func bufferRowsSplitsOnTheRawNewlineByte() {
        // getBufferAsData joins rows with a single 0x0A. Splitting on the byte (not a
        // Swift Character) is what keeps a row that ends in "\r" from being glued to the
        // next row: "\r" + separator "\n" is ONE Character, so a Character-level split
        // would miss the boundary (feedback_swift_crlf_split.md).
        let data = Data("alpha\r\nbeta\n".utf8)
        let rows = TerminalWindowView.bufferRows(from: data)
        #expect(rows == ["alpha", "beta", ""])
    }

    @Test func bufferRowsRightTrimsSpacesAndTabs() {
        let data = Data("code \t \nnext".utf8)
        #expect(TerminalWindowView.bufferRows(from: data) == ["code", "next"])
    }

    // MARK: - scrollbackCapture

    @Test func scrollbackCaptureKeepsLastLinesJoinsWithCRLFDropsTrailingBlanks() {
        let rows = ["one", "two", "three", "", ""]
        let out = TerminalWindowView.scrollbackCapture(
            rows: rows, lineCharCap: 100, keepLines: 10, totalCharCap: 10_000)
        #expect(out == "one\r\ntwo\r\nthree")
    }

    @Test func scrollbackCaptureKeepsOnlyTheLastKeepLinesRows() {
        let rows = (1...10).map { "line\($0)" }
        let out = TerminalWindowView.scrollbackCapture(
            rows: rows, lineCharCap: 100, keepLines: 3, totalCharCap: 10_000)
        #expect(out == "line8\r\nline9\r\nline10")
    }

    @Test func scrollbackCaptureCapsEachLineToLineCharCap() {
        let out = TerminalWindowView.scrollbackCapture(
            rows: [String(repeating: "x", count: 50)],
            lineCharCap: 8, keepLines: 10, totalCharCap: 10_000)
        #expect(out == String(repeating: "x", count: 8))
    }

    @Test func scrollbackCaptureCapsTotalFromTheEnd() {
        // Rows joined by CRLF make "aaaaa\r\nbbbbb\r\nccccc" — 17 Characters, because
        // each "\r\n" is a single grapheme. suffix is grapheme-counted, so a 10-char
        // cap keeps the last 10 Characters: "bbbb" + CRLF + "ccccc".
        let out = TerminalWindowView.scrollbackCapture(
            rows: ["aaaaa", "bbbbb", "ccccc"],
            lineCharCap: 100, keepLines: 10, totalCharCap: 10)
        #expect(out.count == 10)
        #expect(out == "bbbb\r\nccccc")
    }

    // MARK: - matchCount

    @Test func matchCountIsCaseInsensitiveAndCountsAllOccurrences() {
        let rows = ["Foo foo", "nothing", "FOObar foo"]
        #expect(TerminalWindowView.matchCount(
            rows: rows, term: "foo", perRowCap: 100, maxRows: 100, totalByteCap: 1_000) == 4)
    }

    @Test func matchCountEmptyTermIsZero() {
        #expect(TerminalWindowView.matchCount(
            rows: ["anything"], term: "", perRowCap: 100, maxRows: 100, totalByteCap: 1_000) == 0)
    }

    @Test func matchCountStopsAtMaxRows() {
        // Only the first 2 rows are scanned, so the match in row 3 is not counted.
        let rows = ["hit", "hit", "hit"]
        #expect(TerminalWindowView.matchCount(
            rows: rows, term: "hit", perRowCap: 100, maxRows: 2, totalByteCap: 1_000) == 2)
    }

    @Test func matchCountAppliesPerRowCapBeforeCounting() {
        // The match lives past the per-row cap, so a capped row never sees it.
        let row = String(repeating: "a", count: 20) + "hit"
        #expect(TerminalWindowView.matchCount(
            rows: [row], term: "hit", perRowCap: 10, maxRows: 100, totalByteCap: 1_000) == 0)
    }
}
