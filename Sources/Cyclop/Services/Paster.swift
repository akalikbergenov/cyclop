import AppKit

/// Types the ⌘V that the user would otherwise have to type themselves.
///
/// Picking an entry from the list already puts it on the pasteboard, and that
/// alone is what the panel has always done: the last step, the one press that
/// actually lands the text where the caret is, stayed manual. This does it —
/// which means synthesising a key press into another application, and that is
/// the one thing macOS will not let a process do unasked.
enum Paster {
    /// Whether the app may synthesise key presses at all.
    ///
    /// Read without prompting. The prompt is a separate, deliberate call: a
    /// permission dialog thrown up by a background app the moment it launches
    /// is dismissed unread, and this one is asked for at the only moment it
    /// makes sense — after the user has chosen an entry and is waiting for it
    /// to appear.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Whether the system dialog has already been put up in this run.
    private static var hasAsked = false

    /// Asks with the system's own dialog — at most once per run.
    ///
    /// The ceiling matters. macOS grants this right to *the app on disk*, and
    /// for an ad-hoc signed build "the app on disk" means one exact binary:
    /// there is no stable designated requirement to key the grant to, so TCC
    /// keys it to the code hash and every rebuild produces a stranger. Someone
    /// who has already ticked the box and still gets refused is not helped by
    /// being asked again — they get the same dialog on every paste, which is
    /// how a permission prompt turns into nagging. Asked once, then the panel
    /// says what is wrong in its own footer and offers the two things that
    /// actually help.
    static func requestTrust(force: Bool = false) {
        guard force || !hasAsked else { return }
        hasAsked = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Quits and starts again.
    ///
    /// The blunt instrument, and the one that reliably works: a grant made
    /// while the app is running may or may not reach a process that has already
    /// asked, and there is no notification that says which. A fresh process
    /// asks fresh.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Opens Privacy & Security → Accessibility.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// V, by position rather than by what it prints. See `HotKey.Key`.
    private static let keyCodeV: CGKeyCode = 9

    /// Posts ⌘V to whatever is frontmost.
    ///
    /// Call it only once the picker is off screen: the event goes to the front
    /// application, and while a panel of ours is still standing there the front
    /// application is not the one the user was typing in.
    @discardableResult
    static func pasteToFrontmostApp() -> Bool {
        guard isTrusted else { return false }

        let source = CGEventSource(stateID: .combinedSessionState)
        // The shortcut that opens the picker is ⌘⌥V, and a fast hand is still
        // holding some of it when the entry is chosen. Physical keys held down
        // merge into a synthesised event's flags, so the app underneath would
        // receive ⌘⌥V — which in most editors is not paste but something else
        // entirely. Filtering local keyboard events for the length of the
        // suppression interval leaves the posted event carrying exactly the
        // modifiers set below and nothing the hand happens to be resting on.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
