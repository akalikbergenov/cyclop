import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor, for
/// one reason that decides it: a global monitor is a form of input observation
/// and macOS only hands it out to a process the user has ticked in Privacy &
/// Security → Accessibility. A Carbon hot key needs no permission at all — the
/// window server matches the combination itself and only tells us when it fired,
/// never what else was typed. The panel then opens the first time the shortcut
/// is pressed, on a fresh install, with no trip through System Settings.
///
/// (Pasting *is* input synthesis and does need that permission — see `Paster` —
/// but only at the moment an entry is chosen, and the app can explain itself
/// with the list already on screen.)
@MainActor
final class HotKey {
    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let option = Modifiers(rawValue: UInt32(optionKey))
        static let control = Modifiers(rawValue: UInt32(controlKey))
        static let shift = Modifiers(rawValue: UInt32(shiftKey))
    }

    private var ref: EventHotKeyRef?
    private let identifier: UInt32

    /// Handlers by id. The Carbon callback is a bare C function with no room
    /// for a captured `self`, so the id travels in the event and is looked up
    /// here on the way back.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var installed = false

    /// A recorded combination, straight from Settings.
    ///
    /// The key is a physical code, so a shortcut keeps working after a layout
    /// change. Same reasoning as `NotchPanel.Key`: on a Cyrillic layout the V
    /// key prints "м", and anything matching on characters silently stops
    /// matching for exactly the person typing Russian.
    convenience init?(combo: HotKeyCombo, handler: @escaping () -> Void) {
        guard combo.isUsable else { return nil }
        self.init(keyCode: combo.keyCode, modifiers: Modifiers(rawValue: combo.modifiers), handler: handler)
    }

    /// Returns nil when the combination is already spoken for by another app —
    /// the caller can then say so instead of leaving a dead shortcut behind.
    init?(keyCode: UInt32, modifiers: Modifiers, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        // Four bytes read as a string in Carbon's own debugging output; 'cycl'
        // makes ours recognisable there.
        let hotKeyID = EventHotKeyID(signature: 0x6379_636C, id: identifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers.rawValue,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        Self.handlers[identifier] = handler
    }

    deinit {
        // `deinit` cannot touch main-actor state, and both the Carbon
        // unregistration and the table are main-thread-only. The object is
        // owned by the app delegate for the life of the process, so this only
        // ever runs at teardown; hop rather than reach.
        let ref = ref
        let identifier = identifier
        MainActor.assumeIsolated {
            if let ref { UnregisterEventHotKey(ref) }
            HotKey.handlers[identifier] = nil
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[identifier] = nil
    }

    /// One handler for every hot key the app ever registers. Installed lazily
    /// so an app that registers none pays nothing.
    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr else { return status }
                // The Carbon event dispatcher runs on the main thread; this is
                // the same run loop everything else in the app lives on.
                MainActor.assumeIsolated {
                    HotKey.handlers[id.id]?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
    }
}
