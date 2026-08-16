import AppKit
import ApplicationServices
import Carbon

/// Swallows every input event so the keyboard and trackpad can be wiped.
///
/// The only mechanism that can actually stop an event from reaching the system
/// is a `CGEventTap` in its default, non-listening mode — and that one is gated
/// behind the Accessibility permission. Anything cheaper only steals the focus:
/// the app would look locked while ⌘Q, ⌘Tab and the brightness keys still went
/// through, which is worse than not offering the feature, because a cloth is
/// trusted against a promise that does not hold.
@MainActor
final class KeyboardLock: ObservableObject {
    @Published private(set) var isLocked = false
    /// How far into the three-second hold the release key is, 0…1.
    @Published private(set) var holdProgress: Double = 0
    /// Seconds before the lock lifts on its own.
    @Published private(set) var secondsLeft = Int(autoRelease)
    /// Why the last attempt to lock was refused. Dropped when the tab is
    /// entered: the permission may well have been granted in between, and a pane
    /// still asking for it would be wrong.
    @Published private(set) var refusal: Refusal?

    /// Why a lock ended by itself, with no press behind it — and when.
    ///
    /// Kept apart from `refusal` because the two have opposite lifetimes, and one
    /// setter cannot serve both. The panel is folded whenever the lock is on, so
    /// by the time this is written the pane does not exist; entering the tab is
    /// when it gets read, which is exactly when `refusal` has to be dropped.
    @Published private var lastInterruption: (reason: Refusal, at: Date)?

    /// The interruption while it is still news. Goes stale on its own, because
    /// this describes an event, and a sentence about an event left on screen long
    /// enough starts reading as a description of the present — "it is broken now"
    /// instead of "it stopped a moment ago". Also dropped by the next press,
    /// which answers it.
    ///
    /// A minute comes from that reading, not from any mechanism: there is no
    /// technical moment at which the reason expires, only a point past which it
    /// misinforms.
    var interruption: Refusal? {
        guard let lastInterruption,
              Date().timeIntervalSince(lastInterruption.at) < Self.interruptionShelfLife
        else { return nil }
        return lastInterruption.reason
    }

    static let interruptionShelfLife: TimeInterval = 60

    /// Never configurable. It is the one way out that does not depend on the
    /// user, the app or the tap still working correctly.
    static let autoRelease: TimeInterval = 60
    /// Long enough that a cloth cannot do it by accident, short enough to hold
    /// deliberately. Every text that names it reads it from here.
    static let holdToRelease: TimeInterval = 2
    /// How long the tap outlives the cover, waiting for the release key to come
    /// up. A ceiling rather than a wait: a key that never reports its release —
    /// stuck, or its keyUp lost with the app that had focus — must not hold the
    /// keyboard hostage.
    static let drainTimeout: TimeInterval = 2

    /// Why a lock was refused, or why one ended before it was asked to.
    enum Refusal {
        case noAccess
        case secureInput
        case tapFailed
        /// A previous tap is still being taken down. Unreachable by
        /// construction — a drain is finished before this is checked — and it
        /// exists so that the impossible case cannot be reported as a permission
        /// problem, which is what it used to be folded into.
        case busy
    }

    /// Physical keys, matched by code rather than character: a Cyrillic layout
    /// prints something else entirely, and the way out must not depend on which
    /// layout happened to be active when the cloth came out.
    private enum Key {
        static let escape: Int64 = 53
        static let minus: Int64 = 27
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var ticker: Timer?
    private var lockedAt: Date?
    private var holdStartedAt: Date?
    /// Which of the two release keys is being held, so the drain knows what to
    /// wait for.
    private var heldReleaseKey: Int64?
    /// Key code the tap is still swallowing after the cover came off, if any.
    private var drainKeyCode: Int64?
    private var drainStartedAt: Date?

    /// Whether the Accessibility permission is granted. Read every time rather
    /// than cached: it is granted in System Settings, outside this app, and a
    /// cached "no" would outlive the granting by a whole launch.
    var hasAccess: Bool { AXIsProcessTrusted() }

    /// Whether some app is holding secure event input — a password field, a
    /// password manager, a terminal with secure keyboard entry.
    ///
    /// While it is held, keyboard events do not reach an event tap at all; that
    /// is precisely what the mode is for. The tap would still install and the
    /// cover would still go up, and every keystroke would land in whatever is in
    /// front of it. A lock that only looks like one is the failure this class's
    /// own comment calls worse than having no feature, so it is refused instead.
    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Raises the system's own permission dialog. Called from the pane's second
    /// press, after the explanation — the first press is what asks for it.
    func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lock

    /// `nil` when the lock is on, otherwise why it is not.
    @discardableResult
    func lock() -> Refusal? {
        guard !isLocked else { return nil }

        // A press is the answer to whatever ended the last lock, so the
        // explanation for it has been read and can go.
        lastInterruption = nil

        // A drain still owns a tap, and `isLocked` is already false by then, so
        // it is not what the guard below can rely on: the meaningful state is
        // whether a tap is installed, not whether the cover is up. Installing a
        // second one would orphan the first — the run loop source keeps it
        // alive, it keeps swallowing everything, and `release` only ever knows
        // about the newest. That is input eaten until the process dies.
        if drainKeyCode != nil { finishDrain() }
        guard tap == nil else { return refuse(.busy) }

        guard hasAccess else { return refuse(.noAccess) }
        guard !isSecureInputActive else { return refuse(.secureInput) }

        // Everything, not a hand-picked list: the point is that nothing gets
        // through, and a list is a promise to have remembered every event type
        // macOS has — including the ones it gains later.
        let mask = ~CGEventMask(0)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let lock = Unmanaged<KeyboardLock>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { lock.handle(type, event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return refuse(.tapFailed) }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        lockedAt = Date()
        holdStartedAt = nil
        drainKeyCode = nil
        drainStartedAt = nil
        holdProgress = 0
        secondsLeft = Int(Self.autoRelease)
        refusal = nil
        isLocked = true
        startTicker()
        return nil
    }

    /// Records the reason and hands it back, so every refusal is both returned
    /// to the caller and visible to the pane.
    private func refuse(_ reason: Refusal) -> Refusal {
        refusal = reason
        return reason
    }

    /// Called by the pane when the tab is entered. Drops only the press-time
    /// reason: `interruption` is what the pane came to show, and clearing it here
    /// would erase it one frame after it appeared.
    func clearRefusal() {
        refusal = nil
    }

    func unlock() {
        guard isLocked || drainKeyCode != nil else { return }
        drainKeyCode = nil
        drainStartedAt = nil
        isLocked = false
        release()
    }

    /// Hold satisfied: the cover comes off now, the tap stays a moment longer to
    /// swallow what is left of the held key.
    ///
    /// Auto-repeat is already in flight by the time the hold is satisfied,
    /// and the events it produces do not stop with the lock — dropping the tap
    /// here would send the tail of a held `-` into whatever document is in
    /// front. Only key events are swallowed while draining, so the pointer is
    /// live again the moment the screen comes back.
    private func beginDrain(_ code: Int64) {
        drainKeyCode = code
        drainStartedAt = Date()
        holdStartedAt = nil
        holdProgress = 0
        isLocked = false
    }

    /// Idempotent: the timeout in `tick` and the deferred call from the callback
    /// can both arrive, and the second one must find nothing left to do.
    private func finishDrain() {
        guard drainStartedAt != nil else { return }
        drainKeyCode = nil
        drainStartedAt = nil
        release()
    }

    private func release() {
        ticker?.invalidate()
        ticker = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        lockedAt = nil
        holdStartedAt = nil
        holdProgress = 0
    }

    // MARK: - Events

    /// Returns `nil` for everything, which is what discards the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off if its callback ever takes too long, and says
        // so through these two. Re-enabling is the difference between a lock
        // that recovers and one that silently stopped locking.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)

        // Draining: the cover is already off, and the only thing still swallowed
        // is the key that ended the lock, until it comes back up.
        if let drainKeyCode {
            let isKeyEvent = type == .keyDown || type == .keyUp || type == .flagsChanged
            guard isKeyEvent else { return Unmanaged.passUnretained(event) }
            if type == .keyUp, code == drainKeyCode {
                // Off the callback, deliberately. Tearing the mach port down
                // from inside its own callback — and then still returning to the
                // tap machinery — is probably safe, since the run loop holds the
                // source for the duration, but this is the ordinary way out of
                // the lock and it should not rest on "probably". One extra pass
                // of the run loop costs nothing here.
                DispatchQueue.main.async { [weak self] in self?.finishDrain() }
            }
            return nil
        }

        let isReleaseKey = code == Key.escape || code == Key.minus
        switch type {
        case .keyDown where isReleaseKey:
            // Auto-repeat fires keyDown over and over while the key is held, so
            // the start is only recorded once — otherwise the hold would reset
            // itself every repeat and never complete.
            if holdStartedAt == nil {
                holdStartedAt = Date()
                heldReleaseKey = code
            }
        case .keyUp where isReleaseKey:
            holdStartedAt = nil
            heldReleaseKey = nil
            holdProgress = 0
        case .keyDown, .keyUp:
            // Some other key: an accidental press under the cloth, and the one
            // in-progress hold it must not credit. Modifiers arrive as
            // `.flagsChanged` and deliberately do not reset it — a Shift caught
            // by the cloth must not cost the way out.
            holdStartedAt = nil
            heldReleaseKey = nil
            holdProgress = 0
        default:
            break
        }
        return nil
    }

    private func startTicker() {
        // Never two of them: a second timer would tick forever, unreferenced.
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        // The drain runs after the lock is off, so it is checked first — and it
        // is the only thing this timer still has to do at that point.
        if let drainStartedAt {
            if Date().timeIntervalSince(drainStartedAt) >= Self.drainTimeout { finishDrain() }
            return
        }

        guard isLocked, let lockedAt else { return }
        let now = Date()

        // Secure input can go up mid-wipe: a background app raising a password
        // field is enough. From that moment the cover is a lie — keys reach the
        // app in front, not the tap — so the lock ends rather than keeps a
        // promise it no longer holds. The reason is recorded, or the cover would
        // just disappear and read as a crash.
        if isSecureInputActive {
            unlock()
            lastInterruption = (.secureInput, now)
            return
        }

        if let holdStartedAt, let code = heldReleaseKey {
            let held = now.timeIntervalSince(holdStartedAt)
            holdProgress = min(1, held / Self.holdToRelease)
            if held >= Self.holdToRelease {
                beginDrain(code)
                return
            }
        }

        let elapsed = now.timeIntervalSince(lockedAt)
        secondsLeft = max(0, Int((Self.autoRelease - elapsed).rounded(.up)))
        if elapsed >= Self.autoRelease { unlock() }
    }
}
