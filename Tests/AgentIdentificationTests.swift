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
}
