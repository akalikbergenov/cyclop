import AppKit

/// The window the clipboard picker lives in.
///
/// A panel rather than a window, and `.nonactivatingPanel` for the same reason
/// the notch is: taking the keyboard must not make Cyclop the active
/// application. The whole trick of pasting rests on it — the app the user was
/// typing in stays frontmost the entire time the list is up, so when an entry
/// is chosen there is nothing to switch back to and nothing to wait for.
final class BufferPickerPanel: NSPanel {
    /// Physical key codes. Characters are useless here for the same reason as
    /// everywhere else in this app — see `NotchPanel.Key`.
    enum Key {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121
        static let up: UInt16 = 126
        static let down: UInt16 = 125
        /// 1…9 across the number row, in order.
        static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    /// Every key press, before AppKit does anything with it. Returning true
    /// swallows it.
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Dark whatever the system is, like the notch panel: the list is drawn
        // on a dark blur and its text is white either way.
        appearance = NSAppearance(named: .darkAqua)

        isFloatingPanel = true
        // The status bar's own level, one below the notch panel — the picker
        // is a menu in spirit and belongs above everything the user could have
        // been looking at.
        //
        // Not `.popUpMenu`, which is where a menu would seem to belong: the
        // window server only shows that level for the *active* application,
        // and this app is deliberately never active. The panel was ordered
        // front, reported itself visible, key and unoccluded, and drew
        // nothing at all.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// `sendEvent` rather than `keyDown`, for the reason `NotchPanel` gives:
    /// while the app is inactive `NSApplication` does not consider itself to
    /// have a key window, so nothing routed through it — key equivalents,
    /// `doCommandBySelector` — is ever called. Every event the window receives
    /// still passes through here.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}
