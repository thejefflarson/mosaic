import Darwin
import Foundation

/// Resolves a foreground process name to the manifest `id` it identifies
/// (Docs/ADR/009 decision 4). Pure and unit-testable without a PTY or libproc —
/// `ForegroundAgentIdentifier` below is the thin syscall wrapper that feeds it a
/// real process name.
enum AgentIdentifier {
    /// Binary-name → manifest-id overrides for an agent whose OS-visible foreground
    /// process name doesn't match its own manifest `id` or `aliases` — e.g. an
    /// agent shipped as a Node.js CLI, where the kernel's `comm` name is the
    /// interpreter (`node`), not the agent. Manifest `aliases` (vendored from
    /// herdr) already cover the cases herdr itself knows about; this table is the
    /// documented one-line local fix for the rest.
    ///
    /// DECISION NEEDED (JEF-902 live dogfood, ADR-009 risk 2): nobody has confirmed
    /// Claude Code's actual foreground process name yet. This table assumes it
    /// reports as `node` (its distribution is a Node.js CLI) rather than `claude`.
    /// If dogfooding a live terminal shows a different name, correct the entry
    /// below — that correction *is* the point of keeping this table separate from
    /// the manifest's own `aliases`, which are vendored and not ours to edit.
    static let localAliasTable: [String: String] = [
        "node": "claude",
        "claude-code": "claude",
    ]

    /// Resolve `processName` (a bare basename, not a path) to the manifest id it
    /// identifies, or `nil` for a name that matches nothing — the caller falls
    /// back to ADR-007's generic detection tier. Checked in order: a manifest's own
    /// `id`, then its `aliases`, then `aliasTable`; all case-insensitive, since
    /// `proc_name`'s casing isn't a documented contract even though every real
    /// manifest id/alias/table entry today is lowercase.
    static func resolveManifestID(
        processName: String,
        manifests: [String: CompiledManifest],
        aliasTable: [String: String] = localAliasTable
    ) -> String? {
        let name = processName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }

        for manifest in manifests.values
        where manifest.id.lowercased() == name || manifest.aliases.contains(where: { $0.lowercased() == name }) {
            return manifest.id
        }
        // Guard the alias table's target against the loaded set too: a manifest
        // can be absent (e.g. skipped at load for an unmet min_engine_version, or
        // simply not bundled), and the table must not point at an id that isn't
        // actually usable.
        if let target = aliasTable[name], manifests[target] != nil { return target }
        return nil
    }
}

/// Identifies the agent running in the PTY foreground of a terminal, via
/// `tcgetpgrp` + libproc (Docs/ADR/009 decision 4). Stateless: every method takes
/// the terminal's process state as plain values (or reads them once from
/// `termView.process`) and returns a plain `String?` — nothing here retains a
/// terminal, so wiring this into the ~1 Hz drive path (JEF-902) needs no
/// additional weak-capture discipline beyond what that call site already applies
/// to its own terminal reference (the f7fecc5 retention fix this must not regress).
enum ForegroundAgentIdentifier {
    /// The syscalls `identify` depends on, injectable so its guard and fallback
    /// logic is unit-testable without a real PTY or child process. `.live` is the
    /// only implementation used outside tests.
    struct Environment: Sendable {
        var tcgetpgrp: @Sendable (Int32) -> pid_t
        var processName: @Sendable (pid_t) -> String?

        static let live = Environment(
            tcgetpgrp: { Darwin.tcgetpgrp($0) },
            processName: ForegroundAgentIdentifier.liveProcessName
        )
    }

    /// Identify the agent whose process group is currently in the foreground of
    /// the PTY at `childfd`, given the shell's own pid as recorded by
    /// `LocalProcess.startProcess`. Every failure mode below degrades to `nil` (→
    /// the generic detection tier) rather than crashing or misidentifying:
    ///
    /// - `childfd == -1`: the PTY isn't open (process never started, or already
    ///   torn down by `TerminalWindowView.terminate()`).
    /// - `shellPid == 0`: the shell was never spawned.
    /// - `tcgetpgrp` fails (returns `<= 0`, e.g. the fd isn't a controlling tty):
    ///   fall back to naming `shellPid` itself.
    /// - `tcgetpgrp` returns the shell's *own* pgid (no foreground child is
    ///   running; the shell itself is foreground): same fallback as above, and
    ///   the correct outcome — naming the shell binary (bash/zsh/…) won't match
    ///   any agent manifest, i.e. "no agent running" resolves to nil, not a
    ///   crash and not a stale identification.
    ///
    /// macOS nuance: `tcgetpgrp`'s returned pgid equals the foreground process
    /// group's *leader pid* on this platform, so `processName(pgid)` names the
    /// leader directly — no separate pgid→pid lookup is needed.
    static func identify(
        childfd: Int32,
        shellPid: pid_t,
        manifests: [String: CompiledManifest],
        environment: Environment = .live
    ) -> String? {
        guard childfd != -1, shellPid != 0 else { return nil }
        let pgid = environment.tcgetpgrp(childfd)
        let leaderPid = pgid > 0 ? pgid : shellPid
        guard let name = environment.processName(leaderPid) else { return nil }
        return AgentIdentifier.resolveManifestID(processName: name, manifests: manifests)
    }

    /// Convenience for the real call site (JEF-902): reads `termView.process`'s
    /// `childfd`/`shellPid` and delegates to the pure `identify` above. `process`
    /// is declared `LocalProcess!` by SwiftTerm (always set by
    /// `LocalProcessTerminalView.setup()` in practice) — guarded here anyway, since
    /// every other failure mode in this type degrades to `nil` rather than trusting
    /// a third-party IUO.
    @MainActor
    static func identify(termView: InterceptingTerminalView, manifests: [String: CompiledManifest]) -> String? {
        guard let process = termView.process else { return nil }
        return identify(childfd: process.childfd, shellPid: process.shellPid, manifests: manifests)
    }

    /// `proc_name` (libproc) returns the kernel's `comm` name for `pid`, truncated
    /// to `MAXCOMLEN` (16 bytes incl. NUL on macOS) — irrelevant here, since every
    /// manifest id/alias/local-alias-table entry matched against it is far shorter.
    /// Returns `nil` on any libproc failure (e.g. the process has already exited).
    private static func liveProcessName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_name(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
