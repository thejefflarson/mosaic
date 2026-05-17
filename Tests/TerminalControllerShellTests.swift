import Testing
import Foundation
@testable import Mosaic

/// TerminalController.resolveShell maps a snapshot-supplied shell path to an
/// executable we'll actually spawn. The allowlist is derived from /etc/shells
/// plus the current $SHELL and the built-in defaults, so a tampered
/// workspace.json specifying /tmp/payload falls back to the safe default.
@MainActor
struct TerminalControllerShellTests {

    @Test func unknownExecutableFallsBackToDefault() throws {
        // A real, executable file at a non-allowlisted path.
        let payload = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-shell-test-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: payload.path,
                                       contents: Data("#!/bin/sh\necho pwn\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: payload) }

        let resolved = TerminalController.resolveShell(payload.path)
        #expect(resolved == TerminalController.defaultShell,
                "non-allowlisted executable must fall back to default; got \(resolved)")
    }

    @Test func defaultShellIsAllowed() {
        let resolved = TerminalController.resolveShell(TerminalController.defaultShell)
        // resolveShell may symlink-canonicalise (e.g. /bin/zsh → /private/var/select/sh
        // on some systems) — what matters is that the result is in the allowlist.
        #expect(TerminalController.allowedShells.contains(resolved))
    }

    @Test func binZshIsAllowed() {
        // /bin/zsh is always in the built-in defaults, regardless of /etc/shells.
        let resolved = TerminalController.resolveShell("/bin/zsh")
        #expect(TerminalController.allowedShells.contains(resolved))
    }

    @Test func nonexistentPathFallsBackToDefault() {
        let resolved = TerminalController.resolveShell("/nope/does/not/exist")
        #expect(resolved == TerminalController.defaultShell)
    }

    @Test func relativePathFallsBackToDefault() {
        // Snapshot fields should always be absolute; if a relative path slips
        // through, canonicalisation against cwd is undefined — fall back.
        let resolved = TerminalController.resolveShell("payload")
        #expect(resolved == TerminalController.defaultShell)
    }
}
