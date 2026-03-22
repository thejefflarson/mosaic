import AppKit

/// Convenience extension for registering global key event monitors.
/// Not currently used for production shortcuts (those are in AppDelegate's menu),
/// but available for future "global" canvas shortcuts that should fire even when
/// a terminal has keyboard focus.
extension NSApplication {
    /// Add a local key event monitor for a specific key code + modifiers.
    /// Returns the monitor token — retain it to keep the monitor alive.
    @discardableResult
    func addLocalKeyMonitor(
        for keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        handler: @escaping () -> Void
    ) -> Any {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers {
                handler()
                return nil  // consume the event
            }
            return event
        }!
    }
}
