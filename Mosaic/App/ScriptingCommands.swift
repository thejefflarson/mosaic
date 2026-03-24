import AppKit

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
        let expanded = (path as NSString).expandingTildeInPath
        let found = MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.canvasViewController?
                .focusTerminalInDirectory(expanded) ?? false
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
    override func performDefaultImplementation() -> Any? {
        let raw = evaluatedArguments?["MsAt"] as? String
        let path = raw.map { ($0 as NSString).expandingTildeInPath }
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
