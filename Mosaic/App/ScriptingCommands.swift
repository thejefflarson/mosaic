import AppKit

// MARK: - focus terminal "/path"
//
//   tell application "Mosaic"
//       focus terminal "/Users/jeff/myproject"
//   end tell
//
// Pans the canvas to the first terminal whose cwd matches and makes it active.
// Returns true on success, false if no match is found.

@objc(FocusTerminalCommand)
final class FocusTerminalCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let path = directParameter as? String else {
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            scriptErrorString = "A directory path is required."
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

// MARK: - open terminal at "/path"
//
//   tell application "Mosaic"
//       open terminal at "/Users/jeff/myproject"
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

// MARK: - Application-level scripting properties
//
//   tell application "Mosaic" to get working directory
//   tell application "Mosaic" to get terminal count

extension NSApplication {
    /// KVC key "workingDirectory" — maps to SDEF property code WkDr.
    @objc var workingDirectory: String {
        (delegate as? AppDelegate)?.canvasViewController?
            .activeTerminalWorkingDirectory ?? ""
    }

    /// KVC key "terminalCount" — maps to SDEF property code TmCt.
    @objc var terminalCount: Int {
        (delegate as? AppDelegate)?.canvasViewController?
            .terminalCount ?? 0
    }
}
