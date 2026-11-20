import Foundation
import Testing
@testable import Mosaic

struct AgentRosterTests {

    private static let states: [ActivityState] = [.quiet, .busy, .needsAttention(exitCode: nil),
                                                  .needsAttention(exitCode: 0), .needsAttention(exitCode: 2)]
    private static let activities: [AgentActivity?] = [.working, .blocked, .idle, .unknown, nil]

    private func expected(_ state: ActivityState, _ activity: AgentActivity?) -> AgentGroup {
        if case .needsAttention = state { return .needsYou }
        if activity == .blocked { return .needsYou }
        if activity == .working || state == .busy { return .working }
        return .idle
    }

    @Test func groupMatrix() {
        for state in Self.states {
            for activity in Self.activities {
                #expect(AgentRoster.group(activityState: state, agentActivity: activity) == expected(state, activity),
                        "\(state) \(String(describing: activity))")
            }
        }
    }

    @Test func precedenceCases() {
        #expect(AgentRoster.group(activityState: .needsAttention(exitCode: nil), agentActivity: .working) == .needsYou)
        #expect(AgentRoster.group(activityState: .busy, agentActivity: .blocked) == .needsYou)
        #expect(AgentRoster.group(activityState: .busy, agentActivity: .idle) == .working)
        #expect(AgentRoster.group(activityState: .quiet, agentActivity: .working) == .working)
        #expect(AgentRoster.group(activityState: .quiet, agentActivity: nil) == .idle)
    }

    private func snap(_ state: ActivityState, _ activity: AgentActivity?, since: TimeInterval,
                      id: UUID = UUID()) -> AgentSnapshot {
        AgentSnapshot(id: id, title: "t", cwd: "/", agentID: "claude", agentActivity: activity,
                      activityState: state, stateSince: Date(timeIntervalSince1970: since))
    }

    @Test func ordersByGroupThenAge() {
        let needsOld = snap(.needsAttention(exitCode: nil), .idle, since: 10)
        let needsNew = snap(.needsAttention(exitCode: 1), .idle, since: 50)
        let workOld = snap(.busy, .working, since: 5)
        let workNew = snap(.busy, .working, since: 40)
        let idleOld = snap(.quiet, .idle, since: 1)
        let idleNew = snap(.quiet, .idle, since: 90)
        let result = AgentRoster.ordered([idleOld, workNew, needsNew, idleNew, workOld, needsOld])
        #expect(result == [needsOld, needsNew, workOld, workNew, idleNew, idleOld])
    }

    @Test func tiesBreakOnIDDeterministically() {
        let a = snap(.quiet, .idle, since: 1, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = snap(.quiet, .idle, since: 1, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(AgentRoster.ordered([b, a]) == [a, b])
        #expect(AgentRoster.ordered([a, b]) == [a, b])
    }

    @Test func emptyRosterIsEmpty() {
        #expect(AgentRoster.ordered([]).isEmpty)
    }
}
