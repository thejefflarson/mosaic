import Testing
@testable import Mosaic

/// The faithful manifest engine (Docs/ADR/009 decision #5): region extraction,
/// gate evaluation, priority resolution, and the `skip_state_update` hold —
/// ported from herdr's `manifest.rs`, checked against herdr's OWN inline
/// screen→state fixtures (`src/detect/manifest/tests.rs`, Apache-2.0, ported
/// under the vendored `Vendor/herdr/LICENSE`/`NOTICE`) plus regressions
/// retargeted from `AgentActivityDetectorTests`. This is the ICU-vs-Rust-regex
/// gate: for every fixture below, the Swift engine's match decision must equal
/// herdr's, evaluated against the actual bundled `claude`/`codex`/`devin`
/// manifests — not synthetic stand-ins — so an ICU escape/anchor divergence
/// (the round-1 bug this ticket exists to catch) fails here, in CI, not in
/// the field.
struct AgentEngineTests {
    private static let store = ManifestStore.loadBundled()

    private static func manifest(_ id: String) throws -> CompiledManifest {
        try #require(Self.store.manifestsByID[id])
    }

    // MARK: - Region extraction (herdr tests.rs, ported verbatim)

    @Test func bottomNonEmptyLinesUsesBottomOccurrenceForRepeatedText() {
        let content = "marker\nold\n\nmiddle\nmarker\nnew\n"
        #expect(RegionExtractor.text(forRegion: "bottom_non_empty_lines(2)", screen: content, title: "") == "marker\nnew\n")
    }

    @Test func topNonEmptyLinesUsesTopOccurrenceForRepeatedText() {
        let content = "\nmarker\nold\n\nmiddle\nmarker\nnew\n"
        #expect(RegionExtractor.text(forRegion: "top_non_empty_lines(2)", screen: content, title: "") == "\nmarker\nold\n")
    }

    // MARK: - CRLF line splitting (feedback_swift_crlf_split.md regression)

    @Test func lineSplittingBreaksOnCRLFNotJustLF() {
        // A PTY can emit CRLF. Swift treats "\r\n" as ONE grapheme, so a
        // Character-based `split(separator: "\n")` would NOT split these lines and
        // would collapse the whole screen into one "line" — bottom_non_empty_lines(2)
        // would then return the ENTIRE screen (one non-empty line) instead of the
        // last two lines. The scalar-based `splitIntoLines` splits CRLF correctly.
        //
        // The region *slice* preserves raw bytes, CRs included (herdr's
        // `slice_from_line_index` returns the raw byte range) — so CRLF's region
        // text is the LF text with the CRs put back. Stripping them proves the
        // split happened: the last two non-empty lines, not the whole screen.
        let lf = "marker\nold\n\nmiddle\nmarker\nnew\n"
        let crlf = "marker\r\nold\r\n\r\nmiddle\r\nmarker\r\nnew\r\n"
        let lfRegion = RegionExtractor.text(forRegion: "bottom_non_empty_lines(2)", screen: lf, title: "")
        let crlfRegion = RegionExtractor.text(forRegion: "bottom_non_empty_lines(2)", screen: crlf, title: "")
        #expect(lfRegion == "marker\nnew\n")
        #expect(crlfRegion == "marker\r\nnew\r\n")
        #expect(crlfRegion.replacingOccurrences(of: "\r", with: "") == lfRegion)
    }

    // MARK: - Input cap (DoS guard; NSRegularExpression has no match timeout)

    @Test func evaluateCapsScreenAndTitleToABoundedPrefix() throws {
        // The engine runs backtracking ICU regexes with no match timeout, so it
        // caps its inputs before evaluating. Evaluating an over-cap screen must
        // yield EXACTLY the same result as evaluating its capped prefix — proving
        // the cap is applied (and, since the over-cap call returns promptly here,
        // that a multi-MB title can't hang the ~1 Hz tick JEF-902 will drive).
        let claude = try Self.manifest("claude")
        let box = "──────────────────────────────\n❯ \n──────────────────────────────\n"
        let huge = box + String(repeating: "x", count: AgentEngine.maxScreenScalars)
        let cappedPrefix = String(String.UnicodeScalarView(huge.unicodeScalars.prefix(AgentEngine.maxScreenScalars)))
        let full = AgentEngine.evaluate(manifest: claude, screen: huge, title: "")
        let onPrefix = AgentEngine.evaluate(manifest: claude, screen: cappedPrefix, title: "")
        #expect(full == onPrefix)
    }

    @Test func claudePromptBoxWithCRLFClassifiesLikeLF() throws {
        // End-to-end proof through the real claude manifest: the idle prompt box,
        // CRLF-terminated, must classify exactly as its LF twin. If CRLF collapsed
        // the horizontal-rule lines into one, `prompt_box_body` would find no box
        // and `live_prompt_box` would not fire — the misclassification the
        // Character-split bug would cause.
        let claude = try Self.manifest("claude")
        let lf = AgentEngine.evaluate(manifest: claude, screen: "──────────────────────────────\n❯ \n──────────────────────────────\n", title: "")
        let crlf = AgentEngine.evaluate(manifest: claude, screen: "──────────────────────────────\r\n❯ \r\n──────────────────────────────\r\n", title: "")
        #expect(lf.matchedRuleID == "live_prompt_box")
        #expect(crlf.activity == lf.activity)
        #expect(crlf.matchedRuleID == lf.matchedRuleID)
    }

    // MARK: - Gate / priority / line_regex semantics (herdr tests.rs
    // `rule_semantics_apply_gates_priority_and_line_regex`, ported)

    @Test func gatePriorityAndLineRegexSemantics() throws {
        let manifest = AgentManifest(id: "codex", rules: [
            ManifestRule(id: "low_contains", state: .idle, priority: 1, gate: ManifestGate(contains: ["match"])),
            ManifestRule(id: "high_nested_gates", state: .working, priority: 10, gate: ManifestGate(
                all: [ManifestGate(any: [ManifestGate(regex: ["w[io]n"]), ManifestGate(contains: ["fallback"])])],
                not: [ManifestGate(contains: ["blocked"])],
                contains: ["match"]
            )),
            ManifestRule(id: "line_regex", state: .blocked, priority: 20, gate: ManifestGate(lineRegex: ["^exact line$"])),
        ])
        let compiled = try CompiledManifest(manifest)

        let high = AgentEngine.evaluate(manifest: compiled, screen: "match win", title: "")
        #expect(high.activity == .working)
        #expect(high.matchedRuleID == "high_nested_gates")

        // The `not` exclusion drops the higher-priority rule, so the low-priority
        // plain `contains` rule wins instead.
        let notGate = AgentEngine.evaluate(manifest: compiled, screen: "match win blocked", title: "")
        #expect(notGate.activity == .idle)
        #expect(notGate.matchedRuleID == "low_contains")

        let line = AgentEngine.evaluate(manifest: compiled, screen: "before\nexact line\nafter", title: "")
        #expect(line.activity == .blocked)
        #expect(line.matchedRuleID == "line_regex")
    }

    // MARK: - Priority tie-break

    @Test func equalPriorityTiesGoToTheEarlierRule() throws {
        // herdr's `evaluate_loaded_manifest` only replaces the running best on a
        // STRICTLY higher priority (`previous.priority >= rule.priority` keeps the
        // existing match) — so of two equal-priority matching rules, the one
        // earlier in the file wins, regardless of which state it asserts.
        let manifest = AgentManifest(id: "codex", rules: [
            ManifestRule(id: "first", state: .idle, priority: 5, gate: ManifestGate(contains: ["x"])),
            ManifestRule(id: "second", state: .working, priority: 5, gate: ManifestGate(contains: ["x"])),
        ])
        let compiled = try CompiledManifest(manifest)
        let result = AgentEngine.evaluate(manifest: compiled, screen: "x", title: "")
        #expect(result.matchedRuleID == "first")
        #expect(result.activity == .idle)
    }

    // MARK: - skip_state_update hold

    @Test func skipStateUpdateHoldsThePriorRealState() {
        var hold = SkipStateUpdateHold()
        #expect(hold.held == .unknown)

        let working = AgentEngineMatch(activity: .working, matchedRuleID: "w", skipStateUpdate: false)
        #expect(hold.apply(working) == .working)

        // A skip-matched rule (a transient overlay, e.g. Claude's transcript
        // viewer) must not flip the reported activity to its own `.unknown` state.
        let skip = AgentEngineMatch(activity: .unknown, matchedRuleID: "transcript_viewer", skipStateUpdate: true)
        #expect(hold.apply(skip) == .working)
        #expect(hold.held == .working)

        let blocked = AgentEngineMatch(activity: .blocked, matchedRuleID: "b", skipStateUpdate: false)
        #expect(hold.apply(blocked) == .blocked)
    }

    // MARK: - devin.toml (herdr tests.rs `devin_manifest_detects_idle_working_and_blocked_states`)

    @Test func devinManifestDetectsIdleWorkingAndBlockedStates() throws {
        let devin = try Self.manifest("devin")

        let idle = AgentEngine.evaluate(
            manifest: devin,
            screen: "─────────────────────────────────────────────────────\n❭ Ask Devin to build features, fix bugs, or\n  your code\n─────────────────────────────────────────────────────\nSWE-1.6               Context: 16k / 200k tokens (7%)",
            title: ""
        )
        #expect(idle.activity == .idle)

        let liveFooterIdle = AgentEngine.evaluate(
            manifest: devin,
            screen: "Done.\n\n────────────────────────────────────────────────── (bypass permissions on) ─\n❭\n────────────────────────────────────────────────────────────────────────────\nClaude Opus 4.6 Thinking                                    Context: 38k / 200k tokens (18%)",
            title: ""
        )
        #expect(liveFooterIdle.activity == .idle)
        #expect(liveFooterIdle.matchedRuleID == "live_prompt_footer")

        let welcomeFooterIdle = AgentEngine.evaluate(
            manifest: devin,
            screen: "⠀⠀⠀⠀⠀⣴⣾⣶⡄⠀⠀⠀⠀\n⠀⣴⣾⣶⡾⠛⠿⠟⠃⣴⣾⣶⡄  Devin CLI\n⠀⠛⠿⠟⠃⣴⣾⣶⡾⠛⠿⠟⠃  v2026.5.26-8\n⠀⣤⣶⣦⡄⠻⢿⠿⢷⣤⣶⣦⡄\n⠀⠻⢿⠿⢷⣤⣶⣦⡄⠻⢿⠿⠃  Hybrid\n⠀⠀⠀⠀⠀⠻⢿⠿⠃⠀⠀⠀⠀\n\n───────────────────────────\n❭ Ask Devin to build\n  features, fix bugs, or\n  work on your code\n───────────────────────────\nClaude Opus Looking for\n4.6 Thinkingplan mode? /\n            plan",
            title: ""
        )
        #expect(welcomeFooterIdle.activity == .idle)
        #expect(welcomeFooterIdle.matchedRuleID == "welcome_prompt_footer")

        let working = AgentEngine.evaluate(
            manifest: devin,
            screen: "◔ Reading shell 91b655\n  │ Timeout: 35s\n\n⠀⡆ Running tools · 27s (esc to interrupt)\n─────────────────────────────────────────────────────\n❭ Guide Devin while it works",
            title: ""
        )
        #expect(working.activity == .working)

        let trustPrompt = AgentEngine.evaluate(
            manifest: devin,
            screen: "Do you trust the authors of this directory?\nFor security, devin should not be run in directories\nwith untrusted content.\n❭ 1 Yes, trust /private/tmp/devin-hook-probe\n· 2 No, exit",
            title: ""
        )
        #expect(trustPrompt.activity == .blocked)

        let permissionPrompt = AgentEngine.evaluate(
            manifest: devin,
            screen: "⏺ Running command\n  └ $ sleep 30\n\n❭ 1 Yes  (Approve once)\n· 2 Yes, allow `sleep` commands\n· 3 Yes, always allow `sleep` commands\n· 4 No\n↑↓ select · ↵ confirm · esc cancel",
            title: ""
        )
        #expect(permissionPrompt.activity == .blocked)
    }

    // MARK: - claude.toml OSC rules (herdr tests.rs, ported)

    @Test func claudeOSCTitleBraillePrefixIsWorking() throws {
        // "⠂" is U+2802, in the braille block U+2800-U+28FF.
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: "", title: "⠂ project")
        #expect(result.activity == .working)
        #expect(result.matchedRuleID == "osc_title_working")
    }

    @Test func claudeOSCTitleHalfCircleFramesAreWorking() throws {
        let claude = try Self.manifest("claude")
        for frame in ["◐", "◓", "◑", "◒"] {
            let result = AgentEngine.evaluate(manifest: claude, screen: "", title: "\(frame) Initial conversation with Claude")
            #expect(result.activity == .working, "frame \(frame)")
            #expect(result.matchedRuleID == "osc_title_working", "frame \(frame)")
        }
    }

    @Test func claudeOSCTitleStaticPrefixIsIdle() throws {
        // "✳" is U+2733, the static prefix when Claude is not working.
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: "", title: "✳ Claude Code")
        #expect(result.activity == .idle)
        #expect(result.matchedRuleID == "osc_title_idle")
    }

    @Test func claudeBlockerScreenOutranksIdleOSCTitle() throws {
        // The OSC title shows ✳ (idle, priority 250) but the screen has a bash
        // permission prompt — the screen-based blocked rule (priority 850) wins.
        // The same cross-region resolution this ticket's fire-while-working fix
        // relies on, just for `blocked` instead of `working`.
        let screen = "do you want to proceed?\nbash command: rm -rf /tmp/test\n❯ 1. Yes\n   2. No\n\nEsc to cancel · Tab to amend · ctrl+e to explain\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: screen, title: "✳ Claude Code")
        #expect(result.activity == .blocked)
    }

    @Test func claudeEmptyOSCEmptyScreenIsIdleFallback() throws {
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: "", title: "")
        #expect(result.activity == .idle)
        #expect(result.matchedRuleID == nil)
    }

    // MARK: - codex.toml OSC + screen rules (herdr tests.rs, ported)

    @Test func codexOSCTitleBrailleSpinnerIsWorking() throws {
        // "⠋" is U+280B, in the braille block.
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: "", title: "⠋ llm-proxy")
        #expect(result.activity == .working)
        #expect(result.matchedRuleID == "osc_title_working")
    }

    @Test func codexOSCTitleActionRequiredIsBlocked() throws {
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: "", title: "[ . ] Action Required | llm-proxy")
        #expect(result.activity == .blocked)
        #expect(result.matchedRuleID == "osc_title_blocked")
    }

    @Test func codexOSCTitlePlainIsIdle() throws {
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: "", title: "llm-proxy")
        #expect(result.activity == .idle)
        #expect(result.matchedRuleID == "osc_title_idle")
    }

    @Test func codexTrustDirectoryRequiresLiveTopRegion() throws {
        let codex = try Self.manifest("codex")
        let screen = "> You are in C:\\Users\\user\\project\n\nDo you trust the contents of this\ndirectory? Working with untrusted\ncontents comes with higher risk of\nprompt injection. Trusting the\ndirectory allows project-local config,\nhooks, and exec policies to load.\n\n› 1. Yes, continue\n  2. No, quit\n\nPress enter to continue\n"
        let result = AgentEngine.evaluate(manifest: codex, screen: screen, title: "project")
        #expect(result.activity == .blocked)
        #expect(result.matchedRuleID == "trust_directory")

        // Same phrase, but only reachable through a codex `›` transcript marker
        // (not the live top-of-screen region `top_non_empty_lines(20)` requires) —
        // must NOT match `trust_directory`.
        let transcript = "› > You are in C:\\Users\\user\\project\n\nDo you trust the contents of this\ndirectory? Working with untrusted contents comes with higher risk.\n"
        let transcriptResult = AgentEngine.evaluate(manifest: codex, screen: transcript, title: "project")
        #expect(transcriptResult.activity == .idle)
        #expect(transcriptResult.matchedRuleID != "trust_directory")
    }

    @Test func codexBackgroundTerminalScreenDoesNotOverrideOSCIdle() throws {
        let result = AgentEngine.evaluate(
            manifest: try Self.manifest("codex"),
            screen: "background terminal running · /ps to view · /stop to close\n",
            title: "llm-proxy"
        )
        #expect(result.activity == .idle)
        #expect(result.matchedRuleID == "osc_title_idle")
    }

    @Test func codexScreenWorkingFallbackHandlesStaticOSCTitle() throws {
        let screen = "• I’ll run it and wait for completion.\n\n◦ Working (1m 16s • esc to interrupt) · 1 background…\n\n› Use /skills to list available skills\n\ngpt-5.6-sol default · /work\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: screen, title: "project")
        #expect(result.activity == .working)
        #expect(result.matchedRuleID == "screen_working_fallback")
    }

    @Test func codexOSCWorkingRemainsPreferredOverScreenFallback() throws {
        let screen = "• Working (4s • esc to interrupt)\n\n› Use /skills to list available skills\n\ngpt-5.6-sol default · /work\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: screen, title: "⠸ project")
        #expect(result.activity == .working)
        #expect(result.matchedRuleID == "osc_title_working")
    }

    @Test func codexScreenBlockerOutranksWorkingFallback() throws {
        let screen = "• Working (4s • esc to interrupt)\n› 1. Yes, proceed\nPress enter to confirm or esc to cancel\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: screen, title: "project")
        #expect(result.activity == .blocked)
        #expect(result.matchedRuleID == "live_strong_blocker")
    }

    @Test func codexWeakBlockerOutranksWorkingFallback() throws {
        let screen = "• Working (4s • esc to interrupt)\ndo you want to continue? [y/n]\n› Use /skills to list available skills\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: screen, title: "project")
        #expect(result.activity == .blocked)
        #expect(result.matchedRuleID == "weak_blocker")
    }

    @Test func codexTranscriptViewerOutranksWorkingFallback() throws {
        let screen = "• Working (4s • esc to interrupt)\n› transcript\n↑/↓ to scroll · pgup/pgdn to move · home/end to jump · q to quit · esc to edit prev\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: screen, title: "project")
        #expect(result.activity == .unknown)
        #expect(result.matchedRuleID == "transcript_viewer")
        #expect(result.skipStateUpdate)
    }

    @Test func codexScreenWorkingFallbackIgnoresStaleAndPromptText() throws {
        let codex = try Self.manifest("codex")
        let screens = [
            "◦ Working (1m 16s • esc to interrupt)\n■ Conversation interrupted\n› Use /skills to list available skills\ngpt-5.6-sol default · /work\n",
            "› Explain the text ◦ Working (1m 16s • esc to interrupt)\ngpt-5.6-sol default · /work\n",
            "  ◦ Working (1m 16s • esc to interrupt)\n› Use /skills to list available skills\ngpt-5.6-sol default · /work\n",
        ]
        for screen in screens {
            let result = AgentEngine.evaluate(manifest: codex, screen: screen, title: "project")
            #expect(result.activity == .idle)
            #expect(result.matchedRuleID == "osc_title_idle")
        }
    }

    @Test func codexScreenWorkingFallbackIgnoresInterruptedShortTerminal() throws {
        let screen = "◦ Working (1m 16s • esc to interrupt)\n■ Conversation interrupted\n›\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("codex"), screen: screen, title: "project")
        #expect(result.activity == .idle)
        #expect(result.matchedRuleID == "osc_title_idle")
    }

    @Test func codexOSCWorkingBeatsWeakBlockerScreen() throws {
        // A stale [y/n] on screen triggers weak_blocker at priority 600, but an
        // active braille spinner in the OSC title is priority 1050 — OSC wins.
        let result = AgentEngine.evaluate(
            manifest: try Self.manifest("codex"),
            screen: "do you want to continue? [y/n]\n",
            title: "⠋ llm-proxy"
        )
        #expect(result.activity == .working)
        #expect(result.matchedRuleID == "osc_title_working")
    }

    // MARK: - The fire-while-working fix (the bug v0.11.0 shipped with)
    //
    // The old hand-port fired "done" mid-turn: Claude keeps its `❯` prompt box on
    // screen the WHOLE turn, and a momentarily-missed body spinner frame made
    // `classify` fall through to idle. herdr's manifest fixes this three ways —
    // `osc_title_working` (priority 1100, the stablest signal: the OSC title stays
    // a spinner the entire turn), `live_prompt_box`'s idle being scoped to the
    // `prompt_box_body` region (950, below working), and priority resolution
    // picking the higher-priority working rule when both are on screen at once.

    @Test func promptBoxWithWorkingOSCTitleClassifiesWorkingRegardlessOfBodySpinner() throws {
        let claude = try Self.manifest("claude")
        // A live `❯` prompt box (bracketed by two horizontal rules, satisfying
        // `prompt_box_body`) with no body-line spinner at all — the "momentarily
        // missed frame" case that fired `.idle` in the old detector.
        let promptBox = "──────────────────────────────\n❯ \n──────────────────────────────\n"
        let workingTitle = "⠋ my-project"

        let withoutBodySpinner = AgentEngine.evaluate(manifest: claude, screen: promptBox, title: workingTitle)
        #expect(withoutBodySpinner.activity == .working)
        #expect(withoutBodySpinner.matchedRuleID == "osc_title_working")

        let withBodySpinner = AgentEngine.evaluate(
            manifest: claude,
            screen: "⏵ Working… esc to interrupt\n\(promptBox)",
            title: workingTitle
        )
        #expect(withBodySpinner.activity == .working)

        // Sanity check the control: the SAME prompt box, without a working OSC
        // title, reads idle via `live_prompt_box` — proving the fix is the
        // priority resolution across regions, not `live_prompt_box` itself being
        // broken.
        let controlIdle = AgentEngine.evaluate(manifest: claude, screen: promptBox, title: "")
        #expect(controlIdle.activity == .idle)
        #expect(controlIdle.matchedRuleID == "live_prompt_box")
    }

    // MARK: - Regressions retargeted from `AgentActivityDetectorTests` (herdr
    // bug #352's stale-interrupt lesson), now against the manifest engine and
    // the real `claude.toml` rather than the hand-ported constants.

    @Test func liveTurnLineIsWorking() throws {
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: "⏵ Baking… esc to interrupt", title: "")
        #expect(result.activity == .working)
        #expect(result.matchedRuleID == "live_turn_working")
    }

    @Test func permissionPromptIsBlocked() throws {
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: "Do you want to proceed?\n❯ 1. Yes", title: "")
        #expect(result.activity == .blocked)
    }

    @Test func compactionActivityBulletIsWorking() throws {
        // herdr bug #352's neighbor: compaction is a live activity-bullet + ellipsis
        // line (`live_turn_working`'s second alternative), same as any other "✻
        // Thinking…" turn line — not a dedicated compaction rule.
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: "✻ Compacting conversation…", title: "")
        #expect(result.activity == .working)
        #expect(result.matchedRuleID == "live_turn_working")
    }

    @Test func staleInterruptTextAboveAnIdlePromptIsIdle() throws {
        // The exact bug herdr guards against (and #352): a bullet line mentioning
        // "esc to interrupt" but shaped nothing like a live turn line (no ellipsis,
        // so it doesn't satisfy `live_turn_working`'s activity-bullet alternative)
        // sitting above a real prompt box must not read as working.
        let screen = "· earlier (esc to interrupt) note\n──────────────────────────────\n❯ \n──────────────────────────────\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: screen, title: "")
        #expect(result.activity == .idle)
    }

    @Test func workingWinsOverAPromptBoxOnScreen() throws {
        let screen = "⏵ Working… esc to interrupt\n──────────────────────────────\n❯ \n──────────────────────────────\n"
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: screen, title: "")
        #expect(result.activity == .working)
    }

    @Test func plainShellIsTheKnownAgentIdleFallbackNotUnknown() throws {
        // Deliberate divergence from the old hand port (whose bottom-of-function
        // default was `.unknown`): herdr's own fallback for an agent it has
        // already identified — which is the only case `AgentEngine.evaluate` is
        // ever asked to score, identification being JEF-902's job — is idle, not
        // unknown. `.unknown` is reserved for a screen with no identified agent
        // at all, upstream of this engine.
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: "jeff@mac ~/dev/canvas $ ", title: "")
        #expect(result.activity == .idle)
        #expect(result.matchedRuleID == nil)
    }

    @Test func containsMatchingIsCaseInsensitive() throws {
        let result = AgentEngine.evaluate(manifest: try Self.manifest("claude"), screen: "DO YOU WANT TO PROCEED?\n❯ 1. YES", title: "")
        #expect(result.activity == .blocked)
    }
}
