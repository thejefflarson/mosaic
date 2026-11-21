import Foundation
import Testing
import SwiftTerm
@testable import Mosaic

/// End-to-end integration harness added with the SwiftTerm v2 migration: it drives a
/// REAL SwiftTerm v2 terminal screen — no GUI, no PTY — through Mosaic's actual
/// agent-detection engine, so the port ships proven rather than click-tested.
///
/// Each test feeds representative agent output into a `HeadlessTerminal` (v2's public
/// headless entry point, which owns a public `Terminal`), reads the rendered rows back
/// via the public `Terminal.getLine`, reconstructs the visible screen with the SAME
/// NUL-free/trim conversion `TerminalWindowView.visibleScreenText()` uses, and runs the
/// real compiled manifests (`ManifestStore.loadBundled()`) + `AgentEngine` + the roster
/// grouping against it. This is the proof that v2's snapshot/GPU render path still
/// produces screen text the engine recognizes.
///
/// Feeding and reading happen on one thread with no process attached, so no terminal
/// lock is contended.
@MainActor
struct HeadlessTerminalIntegrationTests {
    private static let store = ManifestStore.loadBundled()

    private static func manifest(_ id: String) throws -> CompiledManifest {
        try #require(store.manifestsByID[id])
    }

    /// Load a fixture screen from `Tests/Fixtures`. Read from the source tree via
    /// `#filePath` (CI builds and runs on the same checkout) so the fixtures need no
    /// test-bundle resource wiring.
    private static func fixture(_ name: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
            .appending(path: "\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Render `screen` into a fresh headless v2 terminal and return its visible text.
    /// Feeding with CRLF lands each fixture line at column 0; the leading clear+home
    /// resets the grid. The read mirrors `TerminalWindowView.visibleScreenText()`'s
    /// conversion (NUL → space, right-trim) so a divergence here is a render-path bug.
    private func renderedScreen(_ screen: String) -> String {
        let headless = HeadlessTerminal(onEnd: { _ in })
        let terminal = headless.terminal!
        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        terminal.feed(text: screen.replacingOccurrences(of: "\n", with: "\r\n"))
        var lines: [String] = []
        lines.reserveCapacity(terminal.rows)
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { lines.append(""); continue }
            lines.append(line.translateToString(
                trimRight: true,
                characterProvider: { let c = $0.getCharacter(); return c == "\0" ? " " : c }))
        }
        return lines.joined(separator: "\n")
    }

    private func activity(_ fixtureName: String, _ manifestID: String) throws -> AgentActivity {
        let screen = renderedScreen(try Self.fixture(fixtureName))
        return AgentEngine.evaluate(manifest: try Self.manifest(manifestID), screen: screen, title: "").activity
    }

    /// Group a recognized agent's activity exactly as the roster does for a live
    /// (constantly-redrawing, hence `.busy`) agent terminal.
    private func group(_ activity: AgentActivity) -> AgentGroup {
        AgentRoster.group(activityState: .busy, agentActivity: activity)
    }

    // MARK: - 1. Agent detection end-to-end (claude)

    @Test func claudeWorkingScreenRendersAndDetectsWorking() throws {
        let activity = try activity("claude_working", "claude")
        #expect(activity == .working)
        #expect(group(activity) == .working)
    }

    @Test func claudeIdleScreenRendersAndDetectsIdle() throws {
        let activity = try activity("claude_idle", "claude")
        #expect(activity == .idle)
        #expect(group(activity) == .idle)
    }

    @Test func claudeBlockedScreenRendersAndDetectsBlocked() throws {
        let activity = try activity("claude_blocked", "claude")
        #expect(activity == .blocked)
        #expect(group(activity) == .needsYou)
    }

    // MARK: - 1 (cont.). Agent detection end-to-end (opencode)

    @Test func opencodeWorkingScreenRendersAndDetectsWorking() throws {
        let activity = try activity("opencode_working", "opencode")
        #expect(activity == .working)
        #expect(group(activity) == .working)
    }

    @Test func opencodeBlockedScreenRendersAndDetectsBlocked() throws {
        let activity = try activity("opencode_blocked", "opencode")
        #expect(activity == .blocked)
        #expect(group(activity) == .needsYou)
    }

    /// The three claude states, grouped together, must bucket Needs-you / Working / Idle
    /// — the roster's whole job.
    @Test func claudeStatesBucketIntoDistinctRosterGroups() throws {
        #expect(group(try activity("claude_blocked", "claude")) == .needsYou)
        #expect(group(try activity("claude_working", "claude")) == .working)
        #expect(group(try activity("claude_idle", "claude")) == .idle)
    }

    // MARK: - The v2 render conversion matches the production screen-scrape

    @Test func renderedScreenPreservesFixtureContentForTheEngine() throws {
        // A guard that the render path didn't silently mangle the agent's own UI glyphs
        // the manifests key on (the braille/box/arrow characters).
        let rendered = renderedScreen(try Self.fixture("claude_idle"))
        #expect(rendered.contains("❯"))
        #expect(rendered.contains("──────────────────────────────"))
    }

    // MARK: - 3. Paste hardening (function boundary; same helpers the paste path uses)

    @Test func stripBracketedPasteMarkersRemovesNestedMarkersToAFixpoint() {
        // Splicing neighbours after one removal can form a fresh marker; the strip must
        // loop until none remain so a poisoned clipboard can't close the paste bracket.
        let nested = "\u{1B}[20\u{1B}[201~0~payload\u{1B}[2\u{1B}[201~01~"
        let cleaned = InterceptingTerminalView.stripBracketedPasteMarkers(nested)
        #expect(!cleaned.contains("\u{1B}[200~"))
        #expect(!cleaned.contains("\u{1B}[201~"))
    }

    @Test func containsPasteNewlineDetectsCRLFViaUnicodeScalars() {
        // Swift collapses "\r\n" into one Character, so this must test scalars, not
        // `contains("\n")`, or a CRLF-only clipboard would skip the multi-line warning.
        #expect(InterceptingTerminalView.containsPasteNewline("ls\r\nrm -rf ~"))
        #expect(InterceptingTerminalView.containsPasteNewline("a\rb"))
        #expect(!InterceptingTerminalView.containsPasteNewline("one safe line"))
    }

    // MARK: - 4. Attention reducer output-burst transitions (quiet → busy → needs-you)

    @Test func outputBurstsDriveQuietToBusyToNeedsYou() {
        var model = TerminalActivityModel()
        // A qualifying busy period needs sustained keystroke-free output spanning
        // busyThreshold, then quietThreshold of silence (ADR 007, decision 5).
        let span = TerminalActivityModel.busyThreshold
        #expect(model.reduce(.outputActivity(at: 0)) == .busy)       // first burst → busy
        #expect(model.reduce(.outputActivity(at: span)) == .busy)    // still streaming
        // Output goes quiet past quietThreshold: busy → needs-you (the turn finished).
        #expect(model.reduce(.quietElapsed(at: span + TerminalActivityModel.quietThreshold))
                == .needsAttention(exitCode: nil))
        // A keystroke clears attention back to quiet.
        #expect(model.reduce(.userKeystroke) == .quiet)
    }
}
