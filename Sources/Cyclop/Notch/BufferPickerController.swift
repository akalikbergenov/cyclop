import AppKit
import Combine
import SwiftUI

/// The keyboard half of the clipboard.
///
/// The panel's own clipboard tab is a hover surface: it is reached with the
/// pointer, read with the eyes and clicked with the mouse, and a copy made
/// three copies ago costs a trip to the top of the screen and back. This is the
/// same history reached without letting go of the keyboard — ⌘⌥V, arrows,
/// Return — and it ends where the user was already typing, which is the part
/// the panel could never do.
@MainActor
final class BufferPickerController {
    private var panel: BufferPickerPanel?
    private let model = BufferPickerModel()
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var dismissWork: DispatchWorkItem?

    /// The history and the cover setting. Both outlive every panel — see
    /// `BufferStore.shared` — so they are held directly rather than reached
    /// through whichever panel happens to exist.
    private let store = BufferStore.shared
    private let privacy = PrivacyMode.shared
    private let settings = Settings.shared

    private static let width: CGFloat = 380
    private static let chromeHeight: CGFloat = 30 + 24 + 2

    init() {}

    /// Registers the shortcut, and re-registers it whenever it is changed.
    ///
    /// ⌘⌥V by default, and deliberately: ⌘⇧V is taken by "paste and match
    /// style" in most editors and by Xcode outright, while ⌘⌥V alone is bound
    /// by very little — Finder's "move item here", which only applies with a
    /// file already cut. The shortcut is registered globally, so anything an
    /// app does with the same combination stops reaching it while Cyclop runs;
    /// that is the price of a system-wide shortcut, and the reason the settings
    /// tab can move it.
    func installHotKey() {
        apply(settings.bufferHotKey)
        // The delivered value, not the property: `@Published` announces from
        // `willSet`, so reading it back here would hand out the combination
        // that was just replaced. See `ShotController.installHotKey`.
        settings.$bufferHotKey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] combo in
                MainActor.assumeIsolated { self?.apply(combo) }
            }
            .store(in: &cancellables)
    }

    /// The old registration goes first, always. Carbon keeps both otherwise,
    /// and the combination the user has just moved away from would go on
    /// opening the list for the rest of the session.
    private func apply(_ combo: HotKeyCombo?) {
        hotKey?.unregister()
        hotKey = nil
        guard let combo else { return }
        hotKey = HotKey(combo: combo) { [weak self] in
            self?.hotKeyPressed()
        }
        if hotKey == nil {
            NSLog("Cyclop: \(combo.label) is already registered by another application")
        }
    }

    func teardown() {
        hotKey?.unregister()
        hotKey = nil
        close()
    }

    var isOpen: Bool { panel?.isVisible == true }

    /// Pressing the shortcut again with the list already up walks down it, the
    /// way ⌘Tab walks the application switcher. The hand is already in the
    /// position; asking it to move to the arrow keys for the second item is a
    /// step for nothing.
    private func hotKeyPressed() {
        if isOpen {
            model.move(by: 1)
        } else {
            open()
        }
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        model.load(store.items)

        let panel = panel ?? makePanel()
        self.panel = panel

        dismissWork?.cancel()
        panel.setFrame(frame(for: model.items.count), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        dismissWork?.cancel()
        dismissWork = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: - Construction

    private func makePanel() -> BufferPickerPanel {
        let panel = BufferPickerPanel(contentRect: frame(for: 0))

        let view = BufferPickerView(
            model: model,
            privacy: privacy,
            onChoose: { [weak self] index in
                self?.model.selection = index
                self?.choose()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        panel.contentView = hosting

        panel.onKeyDown = { [weak self] event in
            self?.handle(event) ?? false
        }

        // Clicking into anything else closes the list. There is no click-outside
        // to catch on a borderless panel, but losing key status says the same
        // thing — and a clipboard picker left standing over another app's window
        // is worse than one that closes too eagerly.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.dismissWork == nil else { return }
                    self.close()
                }
            }
            .store(in: &cancellables)

        return panel
    }

    /// Centred on the screen the pointer is on, a third of the way down.
    ///
    /// Not by the caret: finding it needs the Accessibility permission, which
    /// this app asks for only when a paste is actually attempted, and a picker
    /// that will not appear until permission is granted is a worse first
    /// impression than one that appears somewhere reasonable. Not by the notch
    /// either — the notch is at the top of the screen and the caret usually is
    /// not, and a list one has to look up at is a list one loses their place in.
    private func frame(for count: Int) -> NSRect {
        let body = count == 0 ? 96 : BufferPickerView.bodyHeight(for: model.items)
        let size = CGSize(width: Self.width, height: body + Self.chromeHeight)

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height / 3 - size.height / 2
        )
        return NSRect(origin: origin, size: size).integral
    }

    // MARK: - Keys

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.subtracting([.function, .numericPad]).isEmpty

        // ⌘1…⌘9 land on a row directly. Plain digits are left alone on
        // purpose: they are the start of a filter this list does not have yet,
        // and binding them now would make adding one a breaking change.
        if flags == .command, let digit = BufferPickerPanel.Key.digits.firstIndex(of: event.keyCode) {
            guard model.items.indices.contains(digit) else { return true }
            model.selection = digit
            choose()
            return true
        }

        guard plain || flags == .shift else { return false }

        switch event.keyCode {
        case BufferPickerPanel.Key.up:
            model.move(by: -1)
        case BufferPickerPanel.Key.down:
            model.move(by: 1)
        case BufferPickerPanel.Key.tab:
            // Tab walks the list too, forwards, and ⇧Tab back. Everything else
            // on screen is a list one tabs through; a panel where Tab does
            // nothing at all reads as a panel that is not listening.
            model.move(by: flags == .shift ? -1 : 1)
        case BufferPickerPanel.Key.pageUp:
            model.move(by: -BufferPickerModel.visibleRows)
        case BufferPickerPanel.Key.pageDown:
            model.move(by: BufferPickerModel.visibleRows)
        case BufferPickerPanel.Key.home:
            model.moveToStart()
        case BufferPickerPanel.Key.end:
            model.moveToEnd()
        case BufferPickerPanel.Key.returnKey, BufferPickerPanel.Key.keypadEnter:
            choose()
        case BufferPickerPanel.Key.escape:
            close()
        case BufferPickerPanel.Key.delete, BufferPickerPanel.Key.forwardDelete:
            deleteSelected()
        default:
            return false
        }
        return true
    }

    /// Drops the highlighted entry from the history, keeping the selection
    /// where it stands so a run of unwanted rows can be cleared with a held
    /// key rather than a press and a re-aim each time.
    private func deleteSelected() {
        guard let item = model.selected else { return }
        store.remove(item)
        let index = model.selection
        model.load(store.items)
        if model.items.isEmpty {
            panel?.setFrame(frame(for: 0), display: true)
            return
        }
        model.selection = min(index, model.items.count - 1)
        panel?.setFrame(frame(for: model.items.count), display: true)
    }

    /// Put it on the pasteboard, get out of the way, and type the ⌘V.
    private func choose() {
        guard let item = model.selected else { return }
        store.copy(item)

        guard Paster.isTrusted else {
            // The entry is on the pasteboard either way, so nothing is lost —
            // the user finishes with their own ⌘V this once. Said here, in the
            // window they are already looking at, rather than left to be
            // guessed from a shortcut that seems to do half a job.
            //
            // The system dialog comes up only the first time in a run — see
            // `Paster.requestTrust`. Every paste after that says it here and
            // stays out of the way; the settings tab is where it can be fixed.
            model.needsAccessibility = true
            Paster.requestTrust()
            let work = DispatchWorkItem { [weak self] in
                self?.dismissWork = nil
                self?.close()
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            return
        }

        close()
        // One pass for the panel to leave the screen, so the synthesised ⌘V
        // arrives at the application underneath and not at a window of ours
        // that is still up. A run-loop hop alone is not enough — the window
        // server has to have taken the panel down — so this is a short wall
        // clock delay, short enough to read as instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Paster.pasteToFrontmostApp()
        }
    }
}
