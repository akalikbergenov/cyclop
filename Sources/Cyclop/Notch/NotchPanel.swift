import AppKit

/// Borderless, non-activating panel that lives above the menu bar on every space.
final class NotchPanel: NSPanel {
    /// Off by default: taking key status dims the title bar of whatever the
    /// user is working in and stops their insertion point blinking, which is
    /// far too rude for a panel one merely hovers. The translate tab needs
    /// typing, so it turns this on for as long as it is open.
    ///
    /// `.nonactivatingPanel` is what makes that affordable — the panel gets
    /// keyboard input without the app ever becoming active.
    var acceptsKeyboard = false {
        didSet {
            guard acceptsKeyboard != oldValue else { return }
            if acceptsKeyboard { makeKey() }
            // Giving it back is `releaseKey`, called separately — when it
            // happens matters, and only the controller knows when it is safe.
        }
    }

    /// Hands the key status back.
    ///
    /// There is no supported way to simply give it up, and this app owns no
    /// other window to pass it to. Ordering out and straight back in resigns it;
    /// the panel is borderless and the round trip happens within one pass, so
    /// nothing flickers.
    ///
    /// Deliberately not done from `acceptsKeyboard`. That round trip pulls the
    /// window out from under whatever is drawing into it, and when it landed
    /// before the fold, the fold's animation lost its repaint: the panel stayed
    /// on screen fully expanded with `isOpen` already false — ignoring the
    /// pointer, since there was nothing left to close, and passing clicks
    /// through to the app underneath, since the interactive area had shrunk to
    /// the notch while the picture still showed a panel.
    func releaseKey() {
        guard !acceptsKeyboard, isKeyWindow else { return }
        orderOut(nil)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    /// Physical keys, so the shortcuts survive a keyboard layout change. A
    /// Cyrillic layout answers ⌘C with "с" (U+0441), not "c" (U+0063) — they
    /// are indistinguishable on screen and unequal to every string comparison,
    /// which is why matching on characters quietly fails exactly for the
    /// person typing Russian. Key codes name the key, not what it prints.
    private enum Key {
        static let a: UInt16 = 0
        static let z: UInt16 = 6
        static let x: UInt16 = 7
        static let c: UInt16 = 8
        static let v: UInt16 = 9
    }

    /// ⌘A, ⌘X, ⌘C, ⌘V and ⌘Z are ordinarily key equivalents of the Edit menu,
    /// and an `.accessory` app has no menu bar to carry them — so they never
    /// reach the text view on their own. Installing a main menu just for them
    /// would put one in the menu bar the moment the app was ever activated, so
    /// they are dispatched here instead.
    ///
    /// Caught in `sendEvent` rather than in `performKeyEquivalent`: the latter
    /// is only ever called by `NSApplication` for its key window, and while the
    /// app is inactive it does not consider itself to have one. Every event the
    /// window receives passes through here regardless.
    /// Raised on any press inside the panel, before the press is delivered.
    ///
    /// A tap gesture on the text editor never fires — the text view claims the
    /// mouse down first — so the one place a click on the field can reliably
    /// be noticed is here, where every event the window receives passes.
    var onPress: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, editingAction(for: event) != nil, perform(event) { return }
        // Before `super`, so the window is already key by the time the click
        // reaches the field and places a caret.
        if event.type == .leftMouseDown { onPress?() }
        super.sendEvent(event)
    }

    private func editingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.shift) == .command else { return nil }
        switch event.keyCode {
        case Key.a: return #selector(NSText.selectAll(_:))
        case Key.x: return #selector(NSText.cut(_:))
        case Key.c: return #selector(NSText.copy(_:))
        case Key.v: return #selector(NSText.paste(_:))
        // Undo and redo are informal: nothing declares them, the Edit menu just
        // names the selector and lets the chain find an undo manager.
        case Key.z: return flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    /// Dispatched from our own first responder, not through `NSApp`: a
    /// nil-targeted `sendAction` starts at `NSApp.keyWindow`, and an inactive
    /// app reports that as nil however key this panel actually is.
    private func perform(_ event: NSEvent) -> Bool {
        guard let action = editingAction(for: event), let responder = firstResponder else { return false }
        return responder.tryToPerform(action, with: self)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // The panel is dark whatever the system is: it lies over the notch,
        // which is black on every Mac that has one. Everything drawn by hand
        // already knows that, but the AppKit views behind SwiftUI's controls do
        // not — a `TextField` asks the effective appearance what colour text
        // is, and on a Mac set to light it is told black. The result is a field
        // one can type into and not read: the caret blinks, the text lands, and
        // none of it is visible against the panel.
        appearance = NSAppearance(named: .darkAqua)

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // One notch above the status bar so we cover the menu bar itself.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}
