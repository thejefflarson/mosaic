import Foundation

// MARK: - Region
//
// herdr's engine-v3 region names (Docs/ADR/009 decision #3) — the slice of the
// terminal's visible screen (or OSC-derived title/progress string) a rule's
// matchers run against. `Region` is the single source of truth for the "which
// region names does this engine understand" allow-set: `Tests/AgentManifestTests.swift`'s
// re-vendor gate checks every bundled manifest's `region` string parses here,
// rather than keeping its own copy of the name list.

/// One engine-v3 region. Parsed from a `ManifestRule.region` string (already
/// vendor-time validated by `Scripts/lib/validate_manifests.py` — see that
/// script's `REGION_RE`, which this type mirrors); an unrecognized string still
/// resolves to `nil` here, matching herdr's own `region()` catch-all (`""`),
/// so a schema drift the Python validator somehow missed degrades to "no
/// evidence" instead of a crash.
enum Region: Hashable, Sendable {
    case wholeRecent
    case afterLastPromptMarker
    case beforeCurrentPromptMarker
    case wholeRecentWithoutCurrentPromptMarker
    case currentPromptBlockMarker
    case afterCurrentPromptBlockMarker
    case promptBoxBody
    case abovePromptBox
    case lastNonEmptyAbovePromptBox
    case afterLastHorizontalRule
    case oscTitle
    case oscProgress
    case bottomLines(Int)
    case bottomNonEmptyLines(Int)
    case topNonEmptyLines(Int)

    init?(_ spec: String) {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "whole_recent": self = .wholeRecent
        case "after_last_prompt_marker": self = .afterLastPromptMarker
        case "before_current_prompt_marker": self = .beforeCurrentPromptMarker
        case "whole_recent_without_current_prompt_marker": self = .wholeRecentWithoutCurrentPromptMarker
        case "current_prompt_block_marker": self = .currentPromptBlockMarker
        case "after_current_prompt_block_marker": self = .afterCurrentPromptBlockMarker
        case "prompt_box_body": self = .promptBoxBody
        case "above_prompt_box": self = .abovePromptBox
        case "last_non_empty_above_prompt_box": self = .lastNonEmptyAbovePromptBox
        case "after_last_horizontal_rule": self = .afterLastHorizontalRule
        case "osc_title": self = .oscTitle
        case "osc_progress": self = .oscProgress
        default:
            if let count = Self.count(trimmed, prefix: "bottom_lines") {
                self = .bottomLines(count)
            } else if let count = Self.count(trimmed, prefix: "bottom_non_empty_lines") {
                self = .bottomNonEmptyLines(count)
            } else if let count = Self.topNonEmptyLinesCount(trimmed) {
                self = .topNonEmptyLines(count)
            } else {
                return nil
            }
        }
    }

    /// `bottom_lines(N)` / `bottom_non_empty_lines(N)` — herdr's `region_count`
    /// (`manifest.rs:1325`), which is permissive about the digits (vendor-time
    /// validation is what actually enforces "positive, no leading zero").
    private static func count(_ spec: String, prefix: String) -> Int? {
        guard spec.hasPrefix(prefix) else { return nil }
        let rest = spec.dropFirst(prefix.count)
        guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
        let inner = rest.dropFirst().dropLast()
        guard let value = Int(inner), value >= 0 else { return nil }
        return value
    }

    /// `top_non_empty_lines(N)` — herdr's `top_region_count` (`manifest.rs:1335`)
    /// additionally rejects a leading zero and caps at `u16::MAX`.
    private static func topNonEmptyLinesCount(_ spec: String) -> Int? {
        let prefix = "top_non_empty_lines("
        guard spec.hasPrefix(prefix), spec.hasSuffix(")") else { return nil }
        let inner = spec.dropFirst(prefix.count).dropLast()
        guard !inner.isEmpty, inner.first != "0", inner.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        guard let value = Int(inner), value <= Int(UInt16.max) else { return nil }
        return value
    }
}

// MARK: - Line splitting
//
// herdr's region functions operate on `str::lines()`: split on `\n`, strip a
// trailing `\r` off each line, and — unlike a naive split — a final `\n` does
// not produce a trailing empty line. Shared by the region extractor and the
// gate evaluator's `line_regex` matcher.

/// Mirrors Rust's `str::lines()`: split on the `\n` line-feed scalar and strip a
/// single trailing `\r` off each line. This walks `content.unicodeScalars`, NOT
/// its `Character` view, on purpose — Swift treats a `\r\n` pair as ONE extended
/// grapheme cluster, so `split(separator: "\n" as Character)` silently fails to
/// split CRLF-terminated lines (the exact gotcha in the repo's own memory note
/// `feedback_swift_crlf_split.md`). A PTY can and does emit CRLF, and this is a
/// fidelity port where the line boundary IS the match decision, so it must break
/// on the scalar. A final `\n` produces no trailing empty line (as `str::lines()`).
///
/// The returned `Substring`s' `startIndex` values are valid `String.Index`es
/// into `content` — callers slice `content` directly from a line's `startIndex`
/// (see `lineStart`), without the byte-offset arithmetic `manifest.rs`'s
/// `line_start_offset` needs. The scalar the line ends at is a valid slice bound
/// even mid-`\r\n`, since the next line always starts on a grapheme boundary.
///
/// The number of lines is bounded by `content`'s scalar count, which
/// `AgentEngine.evaluate` caps before any split runs (`maxScreenScalars` /
/// `maxTitleScalars`), so this cannot be driven pathological by a huge screen.
private func splitIntoLines(_ content: String) -> [Substring] {
    guard !content.isEmpty else { return [] }
    let scalars = content.unicodeScalars
    var lines: [Substring] = []
    var lineStart = content.startIndex
    var index = content.startIndex
    while index < content.endIndex {
        let next = scalars.index(after: index)
        if scalars[index] == "\n" {
            var lineEnd = index
            if lineStart < lineEnd {
                let beforeNewline = scalars.index(before: lineEnd)
                if scalars[beforeNewline] == "\r" { lineEnd = beforeNewline }
            }
            lines.append(content[lineStart..<lineEnd])
            lineStart = next
        }
        index = next
    }
    if lineStart < content.endIndex { lines.append(content[lineStart..<content.endIndex]) }
    return lines
}

/// The `String.Index` at which `lines[index]` starts, or `content.endIndex`
/// when `index` is at or past the end — herdr's `line_start_offset`, minus the
/// manual byte-offset arithmetic (see `splitIntoLines`).
private func lineStart(_ content: String, _ lines: [Substring], _ index: Int) -> String.Index {
    index < lines.count ? lines[index].startIndex : content.endIndex
}

/// From `lines[index]` to the true end of `content` (including any trailing
/// newline `lines` doesn't represent) — herdr's `slice_from_line_index`.
private func sliceFromLine(_ content: String, _ lines: [Substring], _ index: Int) -> String {
    String(content[lineStart(content, lines, index)...])
}

private func isBlank(_ line: Substring) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: - Region extraction
//
// A faithful port of herdr's `region()` and its helpers (`manifest.rs`
// ~L1285-1541, Docs/ADR/009 decision #3), including the "structural" regions —
// trivial string-slicing over horizontal rules and codex's `›`/`•■✗✓` markers,
// not TUI-layout modeling.

enum RegionExtractor {
    /// Extracts the region a rule declares, from its raw `region` string.
    /// Unrecognized (including a `Region` parse failure) → `""`, matching
    /// herdr's own catch-all.
    static func text(forRegion spec: String, screen: String, title: String) -> String {
        guard let region = Region(spec) else { return "" }
        return text(for: region, screen: screen, title: title)
    }

    static func text(for region: Region, screen: String, title: String) -> String {
        switch region {
        // OSC regions source from their dedicated fields, not the screen.
        case .oscTitle: return title
        // ConEmu OSC 9;4 progress isn't captured from SwiftTerm yet (Docs/ADR/009
        // decision #3); the one low-priority rule it backs is already covered by
        // `prompt_box_body`. Feed herdr's own "absent" behavior.
        case .oscProgress: return ""

        case .wholeRecent: return screen
        case .afterLastPromptMarker: return afterLastPromptMarker(screen)
        case .beforeCurrentPromptMarker: return beforeCurrentPromptMarker(screen)
        case .wholeRecentWithoutCurrentPromptMarker: return wholeRecentWithoutCurrentPromptMarker(screen)
        case .currentPromptBlockMarker: return currentPromptBlockMarker(screen)
        case .afterCurrentPromptBlockMarker: return afterCurrentPromptBlockMarker(screen)
        case .promptBoxBody: return promptBoxBody(screen)
        case .abovePromptBox: return abovePromptBox(screen)
        case .lastNonEmptyAbovePromptBox: return lastNonEmptyLine(abovePromptBox(screen))
        case .afterLastHorizontalRule: return afterLastHorizontalRule(screen)
        case .bottomLines(let count): return bottomLines(screen, count)
        case .bottomNonEmptyLines(let count): return bottomNonEmptyLines(screen, count)
        case .topNonEmptyLines(let count): return topNonEmptyLines(screen, count)
        }
    }

    // MARK: bottom_lines / bottom_non_empty_lines / top_non_empty_lines

    private static func bottomLines(_ content: String, _ count: Int) -> String {
        let lines = splitIntoLines(content)
        let start = max(0, lines.count - count)
        return sliceFromLine(content, lines, start)
    }

    private static func bottomNonEmptyLines(_ content: String, _ count: Int) -> String {
        let lines = splitIntoLines(content)
        guard let start = nthMatchingIndex(in: lines, count: count, reversed: true, where: { !isBlank($0) }) else {
            return ""
        }
        return sliceFromLine(content, lines, start)
    }

    private static func topNonEmptyLines(_ content: String, _ count: Int) -> String {
        let lines = splitIntoLines(content)
        guard let end = nthMatchingIndex(in: lines, count: count, reversed: false, where: { !isBlank($0) }) else {
            return ""
        }
        return String(content[..<lineStart(content, lines, end + 1)])
    }

    /// The index of the `count`-th line satisfying `predicate`, scanning from
    /// the back when `reversed`, else from the front. Two different callers
    /// need two different "fewer than `count` matched" behaviors, so this
    /// takes `exact`: `bottomNonEmptyLines`/`topNonEmptyLines` mirror Rust's
    /// `.take(count).last()` — if fewer than `count` lines match, the last one
    /// found still counts (`exact: false`); `promptBoxTopBorderIndex` mirrors
    /// `border_count == 2` — a screen with fewer than 2 horizontal rules has NO
    /// prompt box, full stop (`exact: true`).
    private static func nthMatchingIndex(
        in lines: [Substring], count: Int, reversed: Bool, exact: Bool = false, where predicate: (Substring) -> Bool
    ) -> Int? {
        let order = reversed
            ? AnySequence(stride(from: lines.count - 1, through: 0, by: -1))
            : AnySequence(0..<lines.count)
        var found = 0
        var lastMatch: Int?
        for index in order where predicate(lines[index]) {
            found += 1
            lastMatch = index
            if found == count { return index }
        }
        return exact ? nil : lastMatch
    }

    // MARK: codex prompt-marker regions

    private static func isCodexPromptLine(_ line: Substring) -> Bool {
        line == "›" || line.hasPrefix("› ")
    }

    private static func isCodexBlockMarkerLine(_ line: Substring) -> Bool {
        line.hasPrefix("•") || line.hasPrefix("■") || line.hasPrefix("✗") || line.hasPrefix("✓")
    }

    /// The index of the last `›`-prompt line, but only when it's still "current" —
    /// no block-marker line (a new turn) has appeared after it. `nil` otherwise,
    /// including when there's no prompt line at all.
    private static func currentCodexPromptIndex(_ lines: [Substring]) -> Int? {
        guard let promptIndex = lines.lastIndex(where: isCodexPromptLine) else { return nil }
        if lines[(promptIndex + 1)...].contains(where: isCodexBlockMarkerLine) { return nil }
        return promptIndex
    }

    private static func afterLastPromptMarker(_ content: String) -> String {
        let lines = splitIntoLines(content)
        guard let index = lines.lastIndex(where: isCodexPromptLine) else { return content }
        return sliceFromLine(content, lines, index + 1)
    }

    private static func beforeCurrentPromptMarker(_ content: String) -> String {
        let lines = splitIntoLines(content)
        guard let index = currentCodexPromptIndex(lines) else { return content }
        return String(content[..<lineStart(content, lines, index)])
    }

    private static func wholeRecentWithoutCurrentPromptMarker(_ content: String) -> String {
        currentCodexPromptIndex(splitIntoLines(content)) != nil ? "" : content
    }

    private static func currentPromptBlockMarker(_ content: String) -> String {
        let lines = splitIntoLines(content)
        guard let promptIndex = currentCodexPromptIndex(lines) else { return "" }
        guard let line = lines[..<promptIndex].last(where: isCodexBlockMarkerLine) else { return "" }
        return String(line)
    }

    private static func afterCurrentPromptBlockMarker(_ content: String) -> String {
        let lines = splitIntoLines(content)
        guard let promptIndex = currentCodexPromptIndex(lines) else { return "" }
        guard let blockIndex = lines[..<promptIndex].lastIndex(where: isCodexBlockMarkerLine) else { return "" }
        return sliceFromLine(content, lines, blockIndex)
    }

    // MARK: prompt-box / horizontal-rule regions

    /// A horizontal rule: a line whose trimmed text is entirely `─` characters
    /// (any count, even one), or whose trimmed text *starts* with a run of ≥3
    /// `─` followed by other content (e.g. Devin's `── (bypass permissions on) ─`
    /// footer). Ports `is_horizontal_rule` (`manifest.rs:1510`) exactly.
    private static func isHorizontalRule(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ruleChars = trimmed.prefix(while: { $0 == "─" })
        guard !ruleChars.isEmpty else { return false }
        let suffix = trimmed[ruleChars.endIndex...].drop(while: { $0.isWhitespace })
        return suffix.isEmpty || ruleChars.count >= 3
    }

    /// The index of the prompt box's *top* border: scanning from the bottom, the
    /// second horizontal-rule line found (the first is the box's bottom border).
    private static func promptBoxTopBorderIndex(_ lines: [Substring]) -> Int? {
        nthMatchingIndex(in: lines, count: 2, reversed: true, exact: true, where: isHorizontalRule)
    }

    private static func promptBoxBody(_ content: String) -> String {
        let lines = splitIntoLines(content)
        guard let top = promptBoxTopBorderIndex(lines) else { return "" }
        let start = lineStart(content, lines, top + 1)
        let endIndex = lines[(top + 1)...].firstIndex(where: isHorizontalRule) ?? lines.count
        let end = lineStart(content, lines, endIndex)
        return String(content[start..<end])
    }

    private static func abovePromptBox(_ content: String) -> String {
        let lines = splitIntoLines(content)
        guard let top = promptBoxTopBorderIndex(lines) else { return content }
        return String(content[..<lineStart(content, lines, top)])
    }

    private static func afterLastHorizontalRule(_ content: String) -> String {
        let lines = splitIntoLines(content)
        guard let index = lines.lastIndex(where: isHorizontalRule) else { return content }
        return sliceFromLine(content, lines, index + 1)
    }

    private static func lastNonEmptyLine(_ content: String) -> String {
        String(splitIntoLines(content).last(where: { !isBlank($0) }) ?? "")
    }
}

// MARK: - Gate evaluation
//
// A faithful port of `compiled_gate_matches` (`manifest.rs:1236`, Docs/ADR/009
// decision #5): every `contains` needle a substring of the lowercased region
// text, every `regex` matching the raw region text, every `line_regex`
// matching at least one line each, every `all` child matching, at least one
// `any` child matching when `any` is non-empty, and no `not` child matching.

private func regexMatches(_ regex: CompiledRegex, in text: String, range: NSRange) -> Bool {
    regex.expression.firstMatch(in: text, options: [], range: range) != nil
}

/// Matches a `line_regex` pattern against one line, using that line's OWN
/// `NSRange` — not a slice of the parent region's range. An `NSRange` only
/// narrows *where* `NSRegularExpression` searches; it doesn't redefine what
/// `^`/`$` anchor to within the larger string, so a pattern anchored to a
/// line's start/end must be matched against the line as its own string.
private func lineRegexMatches(_ regex: CompiledRegex, _ line: Substring) -> Bool {
    let lineText = String(line)
    return regexMatches(regex, in: lineText, range: NSRange(lineText.startIndex..<lineText.endIndex, in: lineText))
}

/// `lowerText`, `lines`, and `range` are all pure derivations of `text` for
/// this rule's region — computed once per rule (`AgentEngine.evaluate`, itself
/// memoized per distinct region across a manifest's rules) and threaded
/// through unchanged here, since herdr's own `compiled_gate_matches` passes
/// the same `text`/`lower_text` down through every nested `all`/`any`/`not`
/// gate rather than re-deriving them per gate.
private func gateMatches(_ gate: CompiledGate, text: String, lowerText: String, lines: [Substring], range: NSRange) -> Bool {
    for needle in gate.contains where !lowerText.contains(needle) { return false }
    for regex in gate.regex where !regexMatches(regex, in: text, range: range) { return false }
    for regex in gate.lineRegex where !lines.contains(where: { lineRegexMatches(regex, $0) }) { return false }
    for nested in gate.all where !gateMatches(nested, text: text, lowerText: lowerText, lines: lines, range: range) {
        return false
    }
    if !gate.any.isEmpty
        && !gate.any.contains(where: { gateMatches($0, text: text, lowerText: lowerText, lines: lines, range: range) }) {
        return false
    }
    if gate.not.contains(where: { gateMatches($0, text: text, lowerText: lowerText, lines: lines, range: range) }) {
        return false
    }
    return true
}

// MARK: - AgentActivity

/// An AI coding agent's screen-scraped turn state (Docs/ADR/009). Claude Code and
/// opencode don't reliably emit a machine-readable signal on turn completion, so —
/// like herdr — the engine reads the visible screen (and OSC title) and recognizes
/// the agent's own UI. Result is a heuristic, not a contract — treat timing as best
/// effort.
enum AgentActivity: Equatable {
    /// A turn is in progress (a live spinner/interrupt line, or compaction running).
    case working
    /// A permission / confirmation prompt is up — the agent needs a decision now.
    case blocked
    /// The agent's input prompt (`❯`) is shown — it finished and is waiting for you.
    case idle
    /// Not an agent screen we recognize (a plain shell, a pager, etc.) — or, for an
    /// already-identified agent, a rule matched with `skip_state_update` and no prior
    /// real state has been observed yet (see `SkipStateUpdateHold`).
    case unknown
}

// MARK: - Engine

/// One `AgentEngine.evaluate` call's outcome — the winning rule's identity
/// alongside the `AgentActivity` JEF-902's call site consumes, so a caller
/// (tests, or the `skip_state_update` hold below) can see *which* rule
/// matched without re-running the evaluator.
struct AgentEngineMatch: Equatable, Sendable {
    let activity: AgentActivity
    /// `nil` when no rule matched (the known-agent idle fallback below).
    let matchedRuleID: String?
    let skipStateUpdate: Bool
}

/// A region's extracted text alongside the values every gate check derives
/// from it — computed once per distinct `Region` per `AgentEngine.evaluate`
/// call (see that function's cache) rather than once per rule, since real
/// manifests reuse a handful of regions across many rules (e.g. claude.json's
/// `whole_recent` backs 4 of its 16 rules).
private struct RegionEvaluation {
    let text: String
    let lowerText: String
    let lines: [Substring]
    let range: NSRange

    init(region: Region, screen: String, title: String) {
        text = RegionExtractor.text(for: region, screen: screen, title: title)
        lowerText = text.lowercased()
        lines = splitIntoLines(text)
        range = NSRange(text.startIndex..<text.endIndex, in: text)
    }
}

/// Evaluates a compiled manifest against one screen/title snapshot and resolves
/// `AgentActivity` — the pure engine behind `ManifestStore`'s compiled types
/// (JEF-899). `nonisolated`, holds no reference to any view/VC/PTY; every
/// input is a value passed in, so it's safe to call from any isolation domain
/// (JEF-902 decides where).
enum AgentEngine {
    /// Mirrors `evaluate_loaded_manifest`'s rule loop (`manifest.rs:445`):
    /// every rule is evaluated (not short-circuited by priority order — file
    /// order is independent of priority order), and the highest-priority match
    /// wins. Ties are NOT re-decided — the running best is replaced only on a
    /// *strictly* higher priority, so the earlier rule in the file wins a tie
    /// (mirrors herdr's `previous.priority >= rule.priority` guard exactly).
    ///
    /// A manifest with no matching rule falls back to `.idle` — not `.unknown`
    /// — because `evaluate` is only ever asked to score an already-identified
    /// agent's manifest (identification is JEF-902's PTY-foreground-process
    /// lookup); herdr's own fallback for a *known* agent with no rule evidence
    /// is idle (`DEFAULT_KNOWN_AGENT_IDLE_FALLBACK`), reserving `.unknown` for
    /// an unrecognized screen with no identified agent at all, which this
    /// function is never handed.
    /// Input ceilings, enforced before any regex runs. A terminal screen is
    /// normally row×col-bounded, but the OSC-2 title is NOT — a program can emit
    /// a multi-megabyte title string — and `NSRegularExpression` (ICU) has no
    /// match timeout, so an unbounded region fed to a backtracking pattern is a
    /// UI-freeze DoS once JEF-902 wires this to the ~1 Hz @MainActor tick. The
    /// guard is an input cap, not a regex timeout (ICU offers none): cap the
    /// screen and title to a fixed scalar ceiling here, at the sole evaluation
    /// chokepoint (`classify` delegates to `evaluate`), so every downstream
    /// region slice, line split, and regex sees a bounded string by construction.
    /// The caps are far above any real agent TUI (a full scrollback screen is a
    /// few KB; a real OSC title, tens of bytes), so truncation only ever clips
    /// adversarial input, degrading it toward the idle fallback rather than
    /// hanging. Scalar-count caps bound the UTF-16 length ICU actually walks.
    static let maxScreenScalars = 64 * 1024
    static let maxTitleScalars = 4 * 1024

    /// Truncate `text` to at most `limit` Unicode scalars, at a scalar boundary
    /// (safe for the scalar-based `splitIntoLines` and every `Character`-level
    /// region helper downstream). Returns `text` unchanged when already within
    /// the cap, avoiding a copy on the overwhelmingly common small-input path.
    private static func capped(_ text: String, to limit: Int) -> String {
        text.unicodeScalars.count <= limit ? text : String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }

    static func evaluate(manifest: CompiledManifest, screen rawScreen: String, title rawTitle: String) -> AgentEngineMatch {
        let screen = capped(rawScreen, to: maxScreenScalars)
        let title = capped(rawTitle, to: maxTitleScalars)
        var regionCache: [Region: RegionEvaluation] = [:]
        var best: CompiledRule?
        for rule in manifest.rules {
            let region: RegionEvaluation
            if let cached = regionCache[rule.region] {
                region = cached
            } else {
                region = RegionEvaluation(region: rule.region, screen: screen, title: title)
                regionCache[rule.region] = region
            }
            let matched = gateMatches(
                rule.gate, text: region.text, lowerText: region.lowerText, lines: region.lines, range: region.range
            )
            guard matched else { continue }
            if let currentBest = best, currentBest.priority >= rule.priority { continue }
            best = rule
        }

        guard let matched = best else {
            return AgentEngineMatch(activity: .idle, matchedRuleID: nil, skipStateUpdate: false)
        }
        return AgentEngineMatch(
            activity: activity(for: matched.state),
            matchedRuleID: matched.id,
            skipStateUpdate: matched.skipStateUpdate
        )
    }

    /// A convenience wrapper over `evaluate` for a caller that doesn't need to hold
    /// `skip_state_update` across calls — `TerminalWindowView.driveAgentActivity`
    /// doesn't use this; it calls `evaluate` directly and threads the result through
    /// its own per-terminal `SkipStateUpdateHold`.
    static func classify(screen: String, title: String, agent manifest: CompiledManifest) -> AgentActivity {
        evaluate(manifest: manifest, screen: screen, title: title).activity
    }

    private static func activity(for state: ManifestState?) -> AgentActivity {
        switch state {
        case .idle: return .idle
        case .working: return .working
        case .blocked: return .blocked
        case .unknown, nil: return .unknown
        }
    }
}

// MARK: - skip_state_update hold

/// Implements herdr's `skip_state_update` semantics (Docs/ADR/009 decision #5):
/// a matched rule with `skip_state_update = true` recognizes a transient
/// overlay (e.g. Claude's transcript viewer, `claude.toml`'s `transcript_viewer`
/// rule) without asserting a real turn state — the terminal's reported
/// `AgentActivity` should keep whatever it was showing before the overlay
/// appeared, not flip to `.unknown` and (in JEF-902's wiring) fire a false
/// generic-tier transition.
///
/// A plain mutating value type, same shape as `TerminalActivityModel` — the
/// owning `TerminalWindowView` holds one per terminal and drives it from the
/// same `@MainActor` tick that already calls `AgentEngine.evaluate`/`classify`,
/// so no locking is needed here; `AgentEngine` itself stays fully stateless.
struct SkipStateUpdateHold: Equatable, Sendable {
    /// Starts `.unknown` — nothing has been observed yet, and a skip-matched
    /// rule on the very first evaluation (unusual, but not impossible) has no
    /// real prior state to fall back to.
    private(set) var held: AgentActivity = .unknown

    init() {}

    /// Feed one `AgentEngine.evaluate` result; returns the `AgentActivity` the
    /// caller should act on — `result.activity` normally, or the held state
    /// when the matched rule set `skip_state_update`.
    @discardableResult
    mutating func apply(_ result: AgentEngineMatch) -> AgentActivity {
        guard !result.skipStateUpdate else { return held }
        held = result.activity
        return held
    }
}
