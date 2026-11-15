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

    @Test func userOwnedShellBinaryIsTrustworthy() throws {
        // A binary owned by the current user (not root) and not group/world-writable
        // must be trusted — e.g. a Homebrew shell at /opt/homebrew (user-owned on
        // Apple Silicon). This is the case that regressed defaultShellIsAllowed.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("myshell")
        FileManager.default.createFile(atPath: bin.path,
                                       contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        #expect(TerminalController.isShellBinaryTrustworthy(atPath: bin.path) == true)
    }

    @Test func writableShellBinaryIsRejected() throws {
        // Group- or world-writable binaries are rejected regardless of owner — anyone
        // else could swap the payload.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for mode in [0o757, 0o775] {   // world-writable, group-writable
            let bin = dir.appendingPathComponent("sh-\(mode)")
            FileManager.default.createFile(atPath: bin.path,
                                           contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: mode])
            #expect(TerminalController.isShellBinaryTrustworthy(atPath: bin.path) == false,
                    "writable binary (mode \(String(mode, radix: 8))) must be rejected")
        }
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
