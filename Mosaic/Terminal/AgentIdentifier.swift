import Darwin
import Foundation

/// Resolves a foreground process name to the manifest `id` it identifies
/// (Docs/ADR/009 decision 4). Pure and unit-testable without a PTY or libproc —
/// `ForegroundAgentIdentifier` below is the thin syscall wrapper that feeds it a
/// real process name.
enum AgentIdentifier {
    /// Binary-name → manifest-id overrides for an agent whose foreground `argv0`
    /// basename doesn't match its own manifest `id` or `aliases`. Manifest
    /// `aliases` (vendored from herdr) already cover the cases herdr itself knows
    /// about; this table is the documented one-line local fix for the rest.
    ///
    /// Empirically settled (was ADR-009 risk 2): Claude Code's foreground `argv0`
    /// basename is `claude` — it launches via `~/.local/bin/claude` (or bare
    /// `claude` on PATH), which matches manifest id `claude` directly, so it needs
    /// no entry here. The earlier `node`→`claude` guess was wrong twice over: a
    /// real Claude process' `argv0` is `claude`, and a real `node` process' is
    /// `node` (an unrelated Node CLI), so mapping `node`→`claude` would both miss
    /// Claude and misidentify plain Node. `claude-code` stays as belt-and-suspenders
    /// (some launchers may use it) though the manifest already lists it as an alias.
    static let localAliasTable: [String: String] = [
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

    /// The foreground process's identifying name: its `argv0` basename (the stable
    /// launcher name, e.g. `claude`), falling back to the kernel `comm` name
    /// (`proc_name`) when `argv0` is unavailable.
    ///
    /// `argv0` is load-bearing, and `proc_name` alone is insufficient: agents now
    /// ship as **versioned self-contained binaries**. Claude Code execs
    /// `~/.local/share/claude/versions/<version>`, so the kernel `comm`
    /// (`proc_name`) is the version string (e.g. `2.1.217`), never `claude` — which
    /// matches no manifest and would drop every Claude terminal to the generic
    /// tier. Its `argv0` is the launcher (`~/.local/bin/claude`, or bare `claude`),
    /// whose basename is the stable `claude`. This is the same signal herdr's own
    /// identifier prefers (`src/detect/mod.rs` `normalized_process_name`:
    /// `argv0 ?? name`). We read only the foreground group leader's `argv0`, not
    /// herdr's full job scan / runtime-unwrap (a node/bun script agent whose argv0
    /// is the interpreter still falls to the generic tier — a documented gap).
    private static func liveProcessName(pid: pid_t) -> String? {
        argv0Basename(pid: pid) ?? procComm(pid: pid)
    }

    /// `argv0` basename via `sysctl(KERN_PROCARGS2)`. Returns nil on any sysctl
    /// failure or malformed buffer; every index is bounds-checked against the
    /// actual returned length so a short/garbage buffer can't trap.
    private static func argv0Basename(pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        let headerSize = MemoryLayout<Int32>.size   // leading argc
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > headerSize else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > headerSize else { return nil }
        // Layout: [argc: Int32][exec_path\0][\0 padding][argv0\0][argv1\0]…
        var i = headerSize
        while i < size, buffer[i] != 0 { i += 1 }   // skip exec_path
        while i < size, buffer[i] == 0 { i += 1 }   // skip NUL padding
        let start = i
        while i < size, buffer[i] != 0 { i += 1 }   // read argv0
        guard i > start else { return nil }
        let argv0 = String(decoding: buffer[start..<i], as: UTF8.self)
        return (argv0 as NSString).lastPathComponent
    }

    /// `proc_name` (libproc) returns the kernel `comm` name for `pid`, truncated to
    /// `MAXCOMLEN`. The `argv0`-unavailable fallback. Returns nil on any libproc
    /// failure (e.g. the process has already exited).
    private static func procComm(pid: pid_t) -> String? {
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
