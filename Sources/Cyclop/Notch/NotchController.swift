import AppKit
import Combine

/// Owns the one shared `NotchViewModel` — the tab, the data, the running
/// services — and one `NotchScreenPanel` per display the panel stands on.
/// Displays come and go far more often than the app relaunches, so the model
/// outlives every reconfiguration; only the windows are rebuilt, and only the
/// ones that actually changed.
@MainActor
final class NotchController {
    private var vm: NotchViewModel?
    private var panels: [CGDirectDisplayID: NotchScreenPanel] = [:]
    private var cancellables = Set<AnyCancellable>()

    func install() {
        let vm = NotchViewModel()
        self.vm = vm
        vm.start()
        rebuild()

        for name in [
            NSApplication.didChangeScreenParametersNotification,
            NotchGeometry.allDisplaysChanged,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
        onWorkspace(NSWorkspace.activeSpaceDidChangeNotification) { $0.activeSpaceChanged() }
        onWorkspace(NSWorkspace.screensDidSleepNotification) { $0.screensSlept() }
        onWorkspace(NSWorkspace.screensDidWakeNotification) { $0.screensWoke() }

        vm.teleprompter.$isRunning
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePin() }
            }
            .store(in: &cancellables)
    }

    /// Sleeping, waking and changing desktop are facts about the session, not
    /// about one display, so every screen hears them.
    private func onWorkspace(_ name: Notification.Name, _ body: @escaping @MainActor (NotchScreenPanel) -> Void) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels.values.forEach(body) }
        }
    }

    func teardown() {
        vm?.stop()
        panels.values.forEach { $0.teardown() }
    }

    /// From the menu bar: opens the panel on the display the pointer is
    /// already on, since that is the screen being looked at.
    func toggle() {
        target()?.toggle()
    }

    /// What the menu bar switches. Handed out rather than wrapped: the menu
    /// reads four sections and writes them one at a time, and a controller
    /// method per section would be four methods that only forward.
    var privacy: PrivacyMode? { vm?.privacy }

    // MARK: - Displays

    /// Diffs the connected displays against what is already built, keyed by
    /// display rather than by position in `NSScreen.screens` — that array
    /// hands out fresh instances on every reconfiguration and reorders them
    /// too. A display whose notch has not moved keeps its panel, open state
    /// and all; only a genuine change or a plug-and-unplug rebuilds anything.
    private func rebuild() {
        guard let vm else { return }
        var next: [CGDirectDisplayID: NotchScreenPanel] = [:]
        for geometry in NotchGeometry.all() {
            guard let id = geometry.displayID else { continue }
            let existing = panels.removeValue(forKey: id)
            if let existing, existing.geometry.matches(geometry) {
                existing.setFrame(geometry.windowFrame)
                next[id] = existing
            } else {
                existing?.teardown()
                let panel = NotchScreenPanel(geometry: geometry, vm: vm)
                panel.state.onChange = { [weak self] in self?.refreshShared() }
                next[id] = panel
            }
        }
        // Whatever is left belonged to a display that just went away.
        panels.values.forEach { $0.teardown() }
        panels = next
        refreshShared()
        updatePin()
    }

    /// The panel the pointer is on; the main display's when it is on none of
    /// them, which is where a menu bar click comes from.
    private func target() -> NotchScreenPanel? {
        let point = NSEvent.mouseLocation
        if let hit = panels.values.first(where: { $0.geometry.screen.frame.contains(point) }) {
            return hit
        }
        return NSScreen.main?.displayID.flatMap { panels[$0] } ?? panels.values.first
    }

    /// A running script pins one screen open — the one it is being read on.
    /// Pinning every screen would be the thing `NotchScreenPanel.setOpen`
    /// warns about: a panel standing open on a display nobody is looking at.
    ///
    /// The screen is chosen once, when the script starts moving, and held
    /// until it stops. If it goes away first — unplugged, or rearranged into a
    /// rebuild — the take ends, for the same reason the display going to sleep
    /// ends it: there is nobody left reading.
    private func updatePin() {
        guard let vm, vm.teleprompter.isRunning else {
            panels.values.forEach { $0.isPinned = false }
            return
        }
        guard !panels.values.contains(where: { $0.isPinned }) else { return }
        guard let owner = panels.values.first(where: { $0.state.isOpen }) else {
            vm.teleprompter.suspend()
            return
        }
        owner.isPinned = true
    }

    // MARK: - Shared state

    /// Recomputes everything the shared model knows about the panels. It has
    /// no panel of its own — there are one or several — so "is anything
    /// showing" and "is anything being typed into" are answers only this can
    /// give, and they are re-asked whenever any screen moves.
    private func refreshShared() {
        guard let vm else { return }
        let active = panels.values.contains { $0.state.isActive }
        vm.isTyping = panels.values.contains { $0.state.wantsKeyboard }
        guard active != vm.isPanelActive else { return }
        vm.isPanelActive = active
        // Polling follows the last panel to close, not the first: a track that
        // is still on screen on one display has to keep ticking while another
        // folds away.
        vm.media.setActive(active)
        vm.calendar.setActive(active)
        guard !active else { return }
        // Whatever was uncovered by hand goes back under cover with the last
        // panel. The next hover is the one nobody planned, and it must not
        // open onto a row somebody revealed ten minutes ago.
        vm.privacy.coverEverything()
        // Menu bar icons come and go with the apps that own them, and how far
        // left they reach is what decides how deep the collapsed target may be.
        // Re-measured with the panel folded: that is both when the target
        // matters again and when rebuilding costs nothing.
        remeasure()
    }

    /// Rebuilds only if a display's notch is no longer what it was measured to
    /// be. `matches` covers everything the panel is cut from, so an unchanged
    /// arrangement with an unchanged menu bar does nothing at all.
    private func remeasure() {
        let fresh = NotchGeometry.all()
        let stale = fresh.count != panels.count || fresh.contains { geometry in
            guard let id = geometry.displayID, let panel = panels[id] else { return true }
            return !panel.geometry.matches(geometry)
        }
        if stale { rebuild() }
    }
}
