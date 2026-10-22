import SwiftUI

/// One button across the whole pane. Deliberately not a list of one: a row
/// layout built for items that do not exist yet would have to be guessed now and
/// redone later anyway, and redoing the inside of a pane is cheap.
struct UtilitiesPane: View {
    @ObservedObject var lock: KeyboardLock

    /// Read from the lock rather than kept here: one of the reasons — secure
    /// input coming up mid-wipe — is raised by a timer with no press behind it,
    /// and a copy in the view would never hear about it.
    ///
    /// An interruption wins: it describes a lock that was running a moment ago,
    /// which is newer news than why an earlier press did not start one.
    private var reason: KeyboardLock.Refusal? { lock.interruption ?? lock.refusal }
    private var wasInterrupted: Bool { lock.interruption != nil }

    var body: some View {
        Button {
            press()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: reason == nil ? "keyboard" : "hand.raised.fill")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(reason == nil ? .white : Color.white.opacity(0.75))

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)

                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.contentAnimation, value: reason)
        // Drops the press-time reason only: the permission may well have been
        // granted in between, and the pane should not still be asking. What the
        // pane came here to show — why a running lock ended — survives, because
        // the panel is folded at the moment that is written and this return is
        // the first chance to read it.
        .onAppear { lock.clearRefusal() }
    }

    private var title: String {
        if wasInterrupted { return localized("Lock ended early") }
        switch lock.refusal {
        case nil: return localized("Lock Keyboard")
        case .noAccess: return localized("Allow in Settings")
        case .secureInput: return localized("Input is protected")
        case .tapFailed: return localized("Could not take over input")
        case .busy: return localized("Still unlocking")
        }
    }

    private var caption: String {
        // A lock that ended is a different message from one that never started:
        // nothing is being asked of the user, something is being reported.
        if wasInterrupted {
            return localized("An app turned on secure keyboard entry, so keys stopped\nreaching the lock. It ended instead of pretending")
        }
        switch lock.refusal {
        case nil:
            return localized(
                "Wipe the keys and the screen. Hold Esc or − for %d s to\nunlock; it also unlocks by itself after a minute",
                Int(KeyboardLock.holdToRelease)
            )
        case .noAccess:
            return localized("Cyclop needs Accessibility to swallow keys and clicks.\nSystem Settings → Privacy & Security → Accessibility")
        case .secureInput:
            return localized("An app is holding secure keyboard entry — a password field,\na password manager, a terminal. Close it and press again")
        case .tapFailed:
            return localized("The system refused the event tap. Re-granting Accessibility\nusually fixes it — the permission is tied to the app's signature")
        case .busy:
            return localized("The previous lock is still being taken down.\nPress again in a moment")
        }
    }

    private func press() {
        // A second press on an explained refusal is the way to Settings: for a
        // missing permission because that is where it is granted, and for a
        // failed tap because a rebuilt app is a new signature to TCC and the
        // stale entry has to be replaced by hand. The other two reasons pass
        // through to another attempt — that is what they are waiting for.
        if let reason, reason == .noAccess || reason == .tapFailed {
            lock.openSettings()
            return
        }

        // The system dialog comes with the explanation, not before it.
        if lock.lock() == .noAccess { lock.requestAccess() }
    }
}
