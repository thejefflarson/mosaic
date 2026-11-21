import Foundation
import Testing
@testable import Mosaic

struct AgentRowFormatTests {

    private func snap(state: ActivityState = .quiet, activity: AgentActivity? = nil) -> AgentSnapshot {
        AgentSnapshot(id: UUID(), title: "t", cwd: "/a/b", agentID: "claude", agentActivity: activity,
                      activityState: state, stateSince: Date())
    }

    @Test func displayNames() {
        #expect(AgentRowFormat.displayName(agentID: "claude") == "Claude")
        #expect(AgentRowFormat.displayName(agentID: "codex") == "Codex")
        #expect(AgentRowFormat.displayName(agentID: "opencode") == "opencode")
        #expect(AgentRowFormat.displayName(agentID: "aider") == "Aider")
    }

    @Test func locationUsesBasenameWithTitleFallback() {
        #expect(AgentRowFormat.location(cwd: "/Users/x/proj/", title: "T", home: "/Users/x") == "proj")
        #expect(AgentRowFormat.location(cwd: "/Users/x", title: "T", home: "/Users/x") == "T")
        #expect(AgentRowFormat.location(cwd: "", title: "T", home: "/Users/x") == "T")
        #expect(AgentRowFormat.location(cwd: "/", title: "T", home: "/Users/x") == "T")
    }

    @Test func durationBuckets() {
        let now = Date()
        #expect(AgentRowFormat.duration(since: now.addingTimeInterval(-59), now: now) == "just now")
        #expect(AgentRowFormat.duration(since: now.addingTimeInterval(-60), now: now) == "1m")
        #expect(AgentRowFormat.duration(since: now.addingTimeInterval(-3599), now: now) == "59m")
        #expect(AgentRowFormat.duration(since: now.addingTimeInterval(-3600), now: now) == "1h")
        #expect(AgentRowFormat.duration(since: now.addingTimeInterval(-7300), now: now) == "2h")
    }

    @Test func reasonAndGlyph() {
        let blocked = snap(activity: .blocked)
        #expect(AgentRowFormat.reason(for: blocked) == "Needs a decision")
        #expect(AgentRowFormat.glyph(for: blocked) == .filledCircle)

        let failed = snap(state: .needsAttention(exitCode: 2))
        #expect(AgentRowFormat.reason(for: failed) == "Finished · exit 2")
        #expect(AgentRowFormat.glyph(for: failed) == .triangle)

        let waiting = snap(state: .needsAttention(exitCode: 0))
        #expect(AgentRowFormat.reason(for: waiting) == "Waiting for you")
        #expect(AgentRowFormat.glyph(for: waiting) == .filledCircle)
        #expect(AgentRowFormat.reason(for: snap(state: .needsAttention(exitCode: nil))) == "Waiting for you")

        #expect(AgentRowFormat.reason(for: snap(state: .busy)) == nil)
        #expect(AgentRowFormat.glyph(for: snap(state: .busy)) == .filledCircle)
        #expect(AgentRowFormat.reason(for: snap()) == nil)
        #expect(AgentRowFormat.glyph(for: snap()) == .hollowCircle)
    }

    @Test func subtitleCombinesReasonAndSessionTitle() {
        // Non-needs-you: just the session title.
        #expect(AgentRowFormat.subtitle(for: snap()) == "t")
        // Needs-you: reason, then the title.
        #expect(AgentRowFormat.subtitle(for: snap(activity: .blocked)) == "Needs a decision · t")
        #expect(AgentRowFormat.subtitle(for: snap(state: .needsAttention(exitCode: 2))) == "Finished · exit 2 · t")

        // With no session title: the reason alone, or nothing at all.
        func titled(_ title: String, state: ActivityState = .quiet, activity: AgentActivity? = nil) -> AgentSnapshot {
            AgentSnapshot(id: UUID(), title: title, cwd: "/a/b", agentID: "claude",
                          agentActivity: activity, activityState: state, stateSince: Date())
        }
        #expect(AgentRowFormat.subtitle(for: titled("", activity: .blocked)) == "Needs a decision")
        #expect(AgentRowFormat.subtitle(for: titled("   ")) == nil)
    }

    @Test func contentHeightSkipsEmptyGroups() {
        let pad: CGFloat = AgentRowFormat.panelTopPadding + AgentRowFormat.panelPadding
        let header: CGFloat = AgentRowFormat.headerHeight
        let needsRow: CGFloat = AgentRowFormat.rowHeightNeedsYou
        let compact: CGFloat = AgentRowFormat.rowHeightCompact
        let idle = snap()
        let needs = snap(activity: .blocked)
        #expect(AgentRowFormat.contentHeight(for: []) == pad)
        #expect(AgentRowFormat.contentHeight(for: [idle]) == pad + header + compact)
        #expect(AgentRowFormat.contentHeight(for: [needs, idle, idle]) == pad + (header + needsRow) + (header + 2 * compact))
    }
}
