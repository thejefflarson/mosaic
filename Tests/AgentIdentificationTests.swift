import Foundation
import Testing
@testable import Mosaic

/// Docs/ADR/009 decision 4 — foreground-process → manifest-id resolution.
/// `AgentIdentifier.resolveManifestID` is pure (no PTY, no libproc); the guard and
/// fallback logic in `ForegroundAgentIdentifier.identify` is exercised below via
/// its injectable `Environment`, so this whole file runs without a real PTY.
struct AgentIdentificationTests {
    /// A minimal compiled manifest — one trivial rule is enough since these tests
    /// only exercise identification, not evaluation.
    private func manifest(id: String, aliases: [String] = []) throws -> CompiledManifest {
        let rule = ManifestRule(id: "r", state: .idle, gate: ManifestGate(contains: ["x"]))
        return try CompiledManifest(AgentManifest(id: id, aliases: aliases, rules: [rule]))
    }

    // MARK: - AgentIdentifier.resolveManifestID (pure)

    @Test func knownManifestIDMatchesDirectly() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        #expect(AgentIdentifier.resolveManifestID(processName: "claude", manifests: manifests) == "claude")
    }

    @Test func manifestAliasMatches() throws {
        let manifests = ["opencode": try manifest(id: "opencode", aliases: ["oc"])]
        #expect(AgentIdentifier.resolveManifestID(processName: "oc", manifests: manifests) == "opencode")
    }

    @Test func matchIsCaseInsensitive() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        #expect(AgentIdentifier.resolveManifestID(processName: "Claude", manifests: manifests) == "claude")
    }

    @Test func localAliasTableEntryMatches() throws {
        // `claude-code` → `claude` via the local alias table.
        let manifests = ["claude": try manifest(id: "claude")]
        #expect(AgentIdentifier.resolveManifestID(processName: "claude-code", manifests: manifests) == "claude")
    }

    @Test func realNodeProcessIsNotClaude() throws {
        // Regression: an unrelated Node CLI's argv0 basename is "node" and MUST NOT
        // resolve to Claude. Claude Code's real argv0 basename is "claude" (it
        // launches via ~/.local/bin/claude), so it matches the manifest id directly
        // and the old node→claude alias — which both missed real Claude and
        // misidentified plain Node — is gone.
        let manifests = ["claude": try manifest(id: "claude")]
        #expect(AgentIdentifier.resolveManifestID(processName: "node", manifests: manifests) == nil)
    }

    @Test func localAliasTableEntryWithoutTargetManifestLoadedReturnsNil() throws {
        // `claude-code` aliases to `claude` in the table, but no manifest is loaded
        // here (e.g. it was skipped for an unmet min_engine_version) — the table
        // must not point at an id that isn't actually usable.
        let manifests: [String: CompiledManifest] = [:]
        #expect(AgentIdentifier.resolveManifestID(processName: "claude-code", manifests: manifests) == nil)
    }

    @Test func unknownNameReturnsNil() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        #expect(AgentIdentifier.resolveManifestID(processName: "bash", manifests: manifests) == nil)
    }

    @Test func emptyNameReturnsNil() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        #expect(AgentIdentifier.resolveManifestID(processName: "", manifests: manifests) == nil)
        #expect(AgentIdentifier.resolveManifestID(processName: "   ", manifests: manifests) == nil)
    }

    // MARK: - ForegroundAgentIdentifier.identify guards (injectable syscalls)

    @Test func closedFileDescriptorFallsBackToGenericTier() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: -1, shellPid: 123, manifests: manifests,
            environment: .init(tcgetpgrp: { _ in 123 }, processName: { _ in "claude" })
        )
        #expect(result == nil)
    }

    @Test func zeroShellPidFallsBackToGenericTier() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 0, manifests: manifests,
            environment: .init(tcgetpgrp: { _ in 123 }, processName: { _ in "claude" })
        )
        #expect(result == nil)
    }

    @Test func tcgetpgrpFailureFallsBackToShellPid() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: .init(tcgetpgrp: { _ in -1 }, processName: { pid in pid == 999 ? "claude" : nil })
        )
        #expect(result == "claude")
    }

    @Test func tcgetpgrpReturningTheShellsOwnGroupNamesTheShell() throws {
        // No foreground child running — the shell itself is foreground. Naming
        // the shell binary ("zsh") correctly matches no manifest.
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: .init(tcgetpgrp: { _ in 999 }, processName: { pid in pid == 999 ? "zsh" : nil })
        )
        #expect(result == nil)
    }

    @Test func foregroundAgentIsIdentifiedByPgidLeaderName() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: .init(tcgetpgrp: { _ in 4242 }, processName: { pid in pid == 4242 ? "claude" : nil })
        )
        #expect(result == "claude")
    }

    @Test func libprocFailureFallsBackToGenericTier() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: .init(tcgetpgrp: { _ in 4242 }, processName: { _ in nil })
        )
        #expect(result == nil)
    }

    @Test func unidentifiableProcessNameFallsBackToGenericTier() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: .init(tcgetpgrp: { _ in 4242 }, processName: { _ in "some-random-shell" })
        )
        #expect(result == nil)
    }

    // MARK: - Subtree search (wrapper peeling)

    /// Build an `Environment` from an explicit process tree: `names[pid]` is a
    /// pid's argv0 basename, `children[pid]` its direct children. `tcgetpgrp`
    /// reports `leader` as the foreground group.
    private func environment(
        leader: pid_t,
        names: [pid_t: String],
        children: [pid_t: [pid_t]]
    ) -> ForegroundAgentIdentifier.Environment {
        .init(
            tcgetpgrp: { _ in leader },
            processName: { names[$0] },
            childPids: { children[$0] ?? [] }
        )
    }

    @Test func wrappedAgentIsFoundBelowTheForegroundWrapper() throws {
        // The ziplock case: foreground leader is the wrapper, the agent its child.
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: environment(leader: 10,
                                     names: [10: "ziplock", 20: "claude"],
                                     children: [10: [20]])
        )
        #expect(result == "claude")
    }

    @Test func agentIsFoundSeveralWrapperLevelsDeep() throws {
        // sh -c → npx → claude: the search descends more than one level.
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: environment(leader: 10,
                                     names: [10: "sh", 20: "npx", 30: "claude"],
                                     children: [10: [20], 20: [30]])
        )
        #expect(result == "claude")
    }

    @Test func directLeaderAgentWinsOverADescendantAgent() throws {
        // Leader is itself an agent; it must win over anything it spawns.
        let manifests = ["claude": try manifest(id: "claude"),
                         "codex": try manifest(id: "codex")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: environment(leader: 10,
                                     names: [10: "claude", 20: "codex"],
                                     children: [10: [20]])
        )
        #expect(result == "claude")
    }

    @Test func breadthFirstPrefersTheShallowerAgent() throws {
        // A depth-1 agent must win over a depth-2 one reachable via a sibling.
        let manifests = ["claude": try manifest(id: "claude"),
                         "codex": try manifest(id: "codex")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: environment(leader: 10,
                                     names: [10: "ziplock", 20: "bash", 30: "claude", 40: "codex"],
                                     children: [10: [20, 30], 20: [40]])
        )
        #expect(result == "claude")
    }

    @Test func subtreeWithNoAgentStillFallsBackToGenericTier() throws {
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: environment(leader: 10,
                                     names: [10: "ziplock", 20: "bash"],
                                     children: [10: [20]])
        )
        #expect(result == nil)
    }

    @Test func cyclicProcessTreeTerminates() throws {
        // A visited set must make a (pathological) parent↔child cycle terminate.
        // Reaching the #expect at all proves the walk didn't loop forever.
        let manifests = ["claude": try manifest(id: "claude")]
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: environment(leader: 10,
                                     names: [10: "a", 20: "b"],
                                     children: [10: [20], 20: [10]])
        )
        #expect(result == nil)
    }

    @Test func searchIsBoundedAndDoesNotReachAnAgentBeyondTheCap() throws {
        // A chain longer than the cap, with the agent at its very end, must not be
        // identified — the bound is a hard stop, not best-effort-with-overrun.
        let manifests = ["claude": try manifest(id: "claude")]
        let depth = ForegroundAgentIdentifier.maxProcessesExamined + 5
        var names: [pid_t: String] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for i in 1...depth {
            names[pid_t(i)] = "wrapper"
            if i < depth { children[pid_t(i)] = [pid_t(i + 1)] }
        }
        names[pid_t(depth)] = "claude"   // agent just past the cap
        let result = ForegroundAgentIdentifier.identify(
            childfd: 5, shellPid: 999, manifests: manifests,
            environment: environment(leader: 1, names: names, children: children)
        )
        #expect(result == nil)
    }
}
