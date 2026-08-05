import AppKit
import Combine

/// Owns the one shared `NotchViewModel` — the tab, the data, the running
/// services — and one `NotchScreenPanel` per connected screen. Screens come
/// and go far more often than the app relaunches, so the view model outlives
/// every reconfiguration; only the per-screen windows are rebuilt, and only
/// the ones that actually need it.
@MainActor
final class NotchController {
    private var viewModel: NotchViewModel?
    private var screens: [CGDirectDisplayID: NotchScreenPanel] = [:]
    /// Creation order, kept for picking a default target screen when the
    /// pointer is not over any of them.
    private var screenOrder: [CGDirectDisplayID] = []

    func install() {
        let vm = NotchViewModel()
        viewModel = vm
        vm.start()
        rebuildScreens()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreens() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screens.values.forEach { $0.handleActiveSpaceChanged() } }
        }
        // A dark display has no hover to watch, so its sampler stops with it.
        // Waking always starts every screen back from the same, folded state.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screens.values.forEach { $0.handleScreensSlept() } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screens.values.forEach { $0.handleScreensWoke() } }
        }
    }

    /// The screenshots folder can be emptied from the menu bar; the shelf has
    /// to notice its files are gone without waiting for a relaunch. One
    /// shared shelf, so one reload reaches every screen.
    func reloadShelf() {
        viewModel?.shelf.load()
    }

    func teardown() {
        viewModel?.stop()
        screens.values.forEach { $0.teardown() }
    }

    /// From the menu bar or the status item click: opens wherever the pointer
    /// already is, or the first screen if it is nowhere near any of them.
    func toggle() {
        targetScreen()?.toggle()
    }

    // MARK: - Screen reconciliation

    /// Diffs the connected screens against what is already built, keyed by
    /// display rather than array position — `NSScreen.screens` hands out a
    /// fresh `NSScreen` instance for the same physical monitor on every
    /// reconfiguration, and can reorder them too. A screen whose geometry has
    /// not moved keeps its panel, open state and all; only a genuine change
    /// or a plug/unplug touches anything.
    private func rebuildScreens() {
        guard let viewModel else { return }
        let fresh = NotchGeometry.all()
        var next: [CGDirectDisplayID: NotchScreenPanel] = [:]
        var order: [CGDirectDisplayID] = []

        for geometry in fresh {
            guard let id = geometry.displayID else { continue }
            order.append(id)
            if let existing = screens.removeValue(forKey: id), existing.geometry.matches(geometry) {
                existing.setFrame(geometry.windowFrame)
                next[id] = existing
            } else {
                screens.removeValue(forKey: id)?.teardown()
                let panel = NotchScreenPanel(geometry: geometry, vm: viewModel)
                panel.state.onActiveChange = { [weak self] in self?.recomputePanelActive() }
                next[id] = panel
            }
        }

        // Whatever is left belonged to a screen that just disconnected.
        screens.values.forEach { $0.teardown() }

        screens = next
        screenOrder = order
        recomputePanelActive()
    }

    private func recomputePanelActive() {
        viewModel?.isPanelActive = screens.values.contains { $0.state.isActive }
    }

    private func targetScreen() -> NotchScreenPanel? {
        let point = NSEvent.mouseLocation
        if let hit = screens.values.first(where: { $0.geometry.screen.frame.contains(point) }) {
            return hit
        }
        return screenOrder.first.flatMap { screens[$0] }
    }
}
