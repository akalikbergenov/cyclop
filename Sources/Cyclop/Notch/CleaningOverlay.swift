import AppKit
import SwiftUI

/// Black cover over every display for as long as the input is locked.
///
/// It earns its place twice: it is the only proof the lock is on — a locked Mac
/// that looks ordinary is indistinguishable from a frozen one — and a black
/// screen is what shows the smudges, so the display gets wiped in the same pass
/// as the keys.
@MainActor
final class CleaningOverlay {
    private var windows: [NSWindow] = []
    private var observer: Any?

    func show(lock: KeyboardLock) {
        guard windows.isEmpty else { return }
        build(lock: lock)
        // Plugging in a display mid-wipe would otherwise leave it uncovered, and
        // an uncovered display is a Mac that looks unlocked while it is not.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.windows.isEmpty else { return }
                self.teardown()
                self.build(lock: lock)
            }
        }
    }

    func hide() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        teardown()
    }

    private func build(lock: KeyboardLock) {
        let screens = NSScreen.screens
        // Decided once, before the loop. Asking each screen in turn whether it
        // holds the pointer *or* happens to be the first one made two screens
        // answer yes as soon as the pointer was on the second: the message was
        // then drawn twice, on different displays.
        let messageIndex = screens.firstIndex { $0.frame.contains(NSEvent.mouseLocation) } ?? 0

        for (index, screen) in screens.enumerated() {
            // Built at zero and framed afterwards, deliberately. The initialiser
            // that takes a `screen:` reads the rect relative to that screen's own
            // lower-left corner, so handing it `screen.frame` — which is already
            // global — adds the origin to itself: a second display at x=1728 got
            // a cover at x=3456, hanging off the side and leaving most of the
            // screen bare. `setFrame` is global and needs no such translation.
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.appearance = NSAppearance(named: .darkAqua)
            window.animationBehavior = .none

            // The message goes on the screen the pointer is on, so it is read
            // where the person is looking; the rest stay plain black.
            let hosting = NSHostingView(
                rootView: CleaningOverlayView(lock: lock, showsMessage: index == messageIndex)
            )
            hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]
            window.contentView = hosting
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    private func teardown() {
        for window in windows {
            window.contentView = nil
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

private struct CleaningOverlayView: View {
    @ObservedObject var lock: KeyboardLock
    let showsMessage: Bool

    var body: some View {
        ZStack {
            Color.black
            if showsMessage {
                VStack(spacing: 18) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 34, weight: .thin))
                        .foregroundStyle(Color.white.opacity(0.55))

                    Text(localized("Keyboard and trackpad are locked"))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))

                    Text(localized("Hold Esc or − for %d s", Int(KeyboardLock.holdToRelease)))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.45))

                    hold

                    Text(localized("Unlocks by itself in %d s", lock.secondsLeft))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shows the hold as it accumulates: without it a three-second press is
    /// indistinguishable from a lock that stopped answering.
    private var hold: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.12))
            Capsule()
                .fill(Color.white.opacity(0.7))
                .frame(width: 180 * lock.holdProgress)
        }
        .frame(width: 180, height: 4)
        .animation(.linear(duration: 1.0 / 20), value: lock.holdProgress)
    }
}
