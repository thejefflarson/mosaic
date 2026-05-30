import AppKit

/// Validate an AppleScript-supplied directory path. macOS Automation TCC gates
/// cross-app scripting, but once permitted any peer can drive spawn/navigate
/// with arbitrary arguments — so we additionally require the resolved path to
/// exist, be a directory, and live under the user's home (rejects /System,
/// /private/var, /Library, /etc paths). Returns the canonical path or nil.
enum ScriptingCwd {
    static func validate(_ raw: String,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard !raw.isEmpty, !raw.contains("\0"), raw.utf8.count <= 4096 else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        let canonicalHome = URL(fileURLWithPath: home.path).resolvingSymlinksInPath().standardizedFileURL
        let homePrefix = canonicalHome.path.hasSuffix("/") ? canonicalHome.path : canonicalHome.path + "/"
        guard canonical.path == canonicalHome.path || canonical.path.hasPrefix(homePrefix) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return canonical.path
    }
}

// MARK: - navigate to "/path"
//
//   tell application "Mosaic"
//       navigate to "/Users/jeff/myproject"   -- returns true/false
//   end tell

@objc(FocusTerminalCommand)
final class FocusTerminalCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let path = directParameter as? String else {
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            scriptErrorString = "A directory path is required (e.g.: navigate to \"/path\")."
            return false
        }
        guard let canonical = ScriptingCwd.validate(path) else { return false as NSNumber }
        let found = MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.canvasViewController?
                .focusTerminalInDirectory(canonical) ?? false
        }
        return found as NSNumber
    }
}

// MARK: - spawn at "/path"
//
//   tell application "Mosaic"
//       spawn at "/Users/jeff/myproject"
//   end tell

@objc(OpenTerminalCommand)
final class OpenTerminalCommand: NSScriptCommand {
    /// Rolling-window rate limit: any peer with Automation TCC consent could
    /// otherwise drive `spawn at` in a tight loop. Combined with the
    /// in-process live-window cap in TerminalController, this bounds the
    /// AppleScript-facing fork-bomb surface.
    private nonisolated(unsafe) static var spawnWindowStart: TimeInterval = 0
    private nonisolated(unsafe) static var spawnsInWindow: Int = 0
    private static let lock = NSLock()
    private static let maxSpawnsPerMinute = 10

    override func performDefaultImplementation() -> Any? {
        let now = ProcessInfo.processInfo.systemUptime
        let allowed: Bool = Self.lock.withLock {
            if now - Self.spawnWindowStart >= 60 {
                Self.spawnsInWindow = 0
                Self.spawnWindowStart = now
            }
            guard Self.spawnsInWindow < Self.maxSpawnsPerMinute else { return false }
            Self.spawnsInWindow += 1
            return true
        }
        guard allowed else {
            scriptErrorNumber = errAEEventNotHandled
            scriptErrorString = "spawn rate limit exceeded (max \(Self.maxSpawnsPerMinute) per minute)"
            return nil
        }
        let path = (evaluatedArguments?["MsAt"] as? String).flatMap { ScriptingCwd.validate($0) }
        MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.canvasViewController?
                .openTerminalViaScript(at: path)
        }
        return nil
    }
}

// MARK: - count terminals
//
//   tell application "Mosaic" to count terminals   -- returns integer

@objc(CountTerminalsCommand)
final class CountTerminalsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let count = MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.canvasViewController?.terminalCount ?? 0
        }
        return count as NSNumber
    }
}

// MARK: - cwd
//
//   tell application "Mosaic" to cwd   -- returns path string

@objc(CwdCommand)
final class CwdCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let dir: String = MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.canvasViewController?
                .activeTerminalWorkingDirectory ?? ""
        }
        return dir
    }
}
