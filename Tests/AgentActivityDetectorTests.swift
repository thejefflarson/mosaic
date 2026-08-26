import Testing
@testable import Mosaic

/// The pure screen-scrape classifier behind agent (Claude Code / opencode) turn
/// detection. Patterns derived from herdr's screen manifests; the load-bearing,
/// cross-agent signal is the interrupt affordance ("esc to interrupt").
struct AgentActivityDetectorTests {

    @Test func interruptAffordanceMeansWorking() {
        // Claude Code's live-turn line.
        #expect(AgentActivityDetector.classify(["⏵ Thinking… (esc to interrupt)"]) == .working)
        // opencode / variant phrasing.
        #expect(AgentActivityDetector.classify(["esc again to interrupt"]) == .working)
    }

    @Test func compactionReadsAsWorkingNotIdle() {
        // Must not be mistaken for "done" mid-compaction (herdr's compacting_busy rule).
        #expect(AgentActivityDetector.classify(["✻ Compacting conversation…"]) == .working)
        #expect(AgentActivityDetector.classify(["Compressing context..."]) == .working)
    }

    @Test func permissionPromptIsBlocked() {
        #expect(AgentActivityDetector.classify(["Do you want to proceed?", "1. Yes  2. No"]) == .blocked)
        #expect(AgentActivityDetector.classify(["Enter to confirm · Esc to cancel"]) == .blocked)
    }

    @Test func promptGlyphWithNoInterruptIsIdle() {
        // Claude's input box with no interrupt line → finished, waiting for you.
        #expect(AgentActivityDetector.classify(["❯ ", "? for shortcuts"]) == .idle)
    }

    @Test func plainShellIsUnknown() {
        #expect(AgentActivityDetector.classify(["jeff@mac ~/dev/canvas $ ", "some output"]) == .unknown)
        #expect(AgentActivityDetector.classify([]) == .unknown)
    }

    @Test func workingWinsOverAPromptGlyphOnScreen() {
        // If both an interrupt line and a prompt glyph are visible, it's still working
        // (the turn hasn't ended) — working is checked first.
        let lines = ["❯ earlier prompt", "⏵ Working… (esc to interrupt)"]
        #expect(AgentActivityDetector.classify(lines) == .working)
    }

    @Test func caseInsensitive() {
        #expect(AgentActivityDetector.classify(["⏵ WORKING… (ESC TO INTERRUPT)"]) == .working)
        #expect(AgentActivityDetector.classify(["DO YOU WANT TO PROCEED?"]) == .blocked)
    }

    @Test func staleInterruptTextAboveAnIdlePromptIsIdle() {
        // The exact bug herdr guards against (and #352): a bare "esc to interrupt"
        // lingering above a fresh prompt must NOT read as working — only a live,
        // spinner-prefixed turn line counts. Otherwise the detector gets stuck busy.
        #expect(AgentActivityDetector.classify(["  · earlier (esc to interrupt) note", "❯ "]) == .idle)
    }

    @Test func brailleSpinnerLineIsWorking() {
        // Claude's live status line starts with a braille spinner (herdr's snippet:
        // "⠋ Baking… (esc to interrupt)").
        #expect(AgentActivityDetector.classify(["⠋ Baking… (13m 36s · esc to interrupt)"]) == .working)
    }
}
