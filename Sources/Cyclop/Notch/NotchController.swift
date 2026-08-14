import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchController {
    private var panel: NotchPanel?
    private var rootView: NotchRootView?
    private var viewModel: NotchViewModel?
    private let pointer = PointerWatcher()
    private var closeActiveRectWork: DispatchWorkItem?
    /// Subscriptions belonging to the current panel. Emptied on every rebuild,
    /// because the objects they watch go with it.
    private var cancellables = Set<AnyCancellable>()
    /// Subscriptions belonging to the controller itself, which outlives every
    /// panel it builds. Kept apart from the set above for one concrete reason:
    /// the settings subscription lives here, and clearing it along with the
    /// panel's would mean the first resize worked and no later one did.
    private var lifetimeCancellables = Set<AnyCancellable>()
    /// Live only while a click-opened panel is on screen.
    private var clickOutsideMonitor: Any?
    private var isClosingAfterClick = false
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0

    func install() {
        build()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
        // The panel's own size is a setting now, and a window cannot be
        // resized into a different shape without being built again: the frame,
        // every hover rect and the click-through region are all derived from
        // the geometry the panel was made with.
        Settings.shared.geometryDidChange
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            }
            .store(in: &lifetimeCancellables)

        // The switch that chooses between hovering and clicking lives inside
        // the panel, so it is always thrown while the panel is open — and each
        // mode's way of closing is set up at the moment of opening. Switched
        // mid-flight, the panel kept the machinery of the mode it was opened in
        // and had none of the new one's: in click mode nothing was watching for
        // the click that would close it, and in hover mode the pointer had
        // already been written off. Either way it stood there.
        Settings.shared.$opensOnHover
            .dropFirst()
            .removeDuplicates()
            // Delivered one pass later, so that everything this ends up
            // calling — and much of it reads the setting again — sees the new
            // value. `@Published` fires from `willSet`, so without the hop the
            // panel would be re-armed for the mode it had just left.
            .receive(on: RunLoop.main)
            .sink { [weak self] hover in
                MainActor.assumeIsolated { self?.modeChanged(toHover: hover) }
            }
            .store(in: &lifetimeCancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
        // A dark display has no hover to watch, so the one timer that never
        // otherwise stops — the pointer sampler — stops with it. The panel
        // closes too, so waking always starts from the same, folded state.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setOpen(false)
                self.pointer.setInside(false)
                self.pointer.stop()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointer.start() }
        }
    }

    /// The screenshots folder can be emptied from the menu bar; the entries
    /// pointing into it have to notice their files are gone without waiting
    /// for a relaunch.
    func reloadBuffer() {
        viewModel?.buffer.dropMissingFiles()
    }

    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    /// Collapsing also puts hover tracking back in step: nothing moved the
    /// mouse, so nothing else would have.
    private func activeSpaceChanged() {
        guard viewModel?.isOpen == true else { return }
        // What was typed is kept — only the panel closes.
        setOpen(false)
        pointer.setInside(false)
    }

    private func screenParametersChanged() {
        let fresh = NotchGeometry.current()
        guard let current = viewModel?.geometry, current.matches(fresh) else {
            rebuild()
            return
        }
        // Same display, same notch: keep the panel and everything on it.
        panel?.setFrame(fresh.windowFrame, display: false)
    }

    func teardown() {
        stopWatchingForClickOutside()
        pointer.stop()
        viewModel?.stop()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
    }

    /// Opens the panel on the settings tab. The menu bar keeps a way in for
    /// people who have not found the gear on the rail — and for the case where
    /// a shortcut was set to something the machine will not give back.
    func showSettings() {
        guard let viewModel else { return }
        viewModel.select(.settings)
        setOpen(true)
        pointer.setInside(true)
    }

    func toggle() {
        guard let viewModel else { return }
        setOpen(!viewModel.isOpen)
        pointer.setInside(viewModel.isOpen)
        // The shortcut opens it the same way a click does, so it closes the
        // same way too.
        if viewModel.isOpen, !Settings.shared.opensOnHover {
            viewModel.wantsKeyboard = true
            watchForClickOutside()
        }
    }

    // MARK: - Construction

    private func rebuild() {
        let previousTab = viewModel?.tab
        let wasOpen = viewModel?.isOpen == true
        pointer.stop()
        viewModel?.stop()
        closeActiveRectWork?.cancel()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        rootView = nil
        viewModel = nil
        build()
        if let previousTab { viewModel?.tab = previousTab }
        // Rebuilt because the user moved a stepper in the settings tab: the
        // panel they are working in must come back, or every press would fold
        // it and the next one would need a trip to the notch first.
        if wasOpen {
            pointer.setInside(true)
            setOpen(true)
            if previousTab?.needsKeyboard == true { viewModel?.wantsKeyboard = true }
        }
    }

    private func build() {
        let geometry = NotchGeometry.current()
        let vm = NotchViewModel(geometry: geometry)
        viewModel = vm

        let panel = NotchPanel(contentRect: geometry.windowFrame)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: geometry.windowSize))
        root.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchContentView(vm: vm))
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        root.addSubview(hosting)

        root.onDragEntered = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.tab = .buffer
            vm.isDropTargeted = true
            self.setOpen(true)
        }
        root.onDragExited = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.isDropTargeted = false
            // The pointer usually is not over the panel after a drag leaves.
            self.scheduleCollapseIfPointerAway()
        }
        root.onDrop = { [weak self] urls in
            guard let self, let vm = self.viewModel else { return false }
            vm.isDropTargeted = false
            let accepted = vm.accept(urls: urls)
            self.pointer.setInside(true)
            self.setOpen(true)
            self.scheduleCollapseIfPointerAway()
            return accepted
        }

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again.
        //
        // The same press is also what opens the panel when hover-to-open is
        // switched off: collapsed, the only thing under the pointer is the
        // notch strip, and a click there is unambiguous.
        panel.onPress = { [weak self] location in
            guard let self, let vm = self.viewModel else { return }
            if !vm.isOpen {
                guard !Settings.shared.opensOnHover else { return }
                self.openByClick()
                return
            }
            // Open already, and the press landed back on the notch: that is
            // the same switch being thrown the other way.
            if !Settings.shared.opensOnHover, vm.geometry.hoverRect.contains(location) {
                self.closeAfterClick()
                return
            }
            guard vm.tab.needsKeyboard else { return }
            vm.wantsKeyboard = true
        }

        panel.onCancel = { [weak self] in
            guard let self, Settings.shared.opensOnHover == false else { return }
            self.closeAfterClick()
        }

        panel.contentView = root
        panel.ignoresMouseEvents = true
        panel.setFrame(geometry.windowFrame, display: false)
        panel.orderFrontRegardless()

        self.panel = panel
        self.rootView = root

        applyActiveRect(open: false)

        pointer.openRect = geometry.hoverRect
        pointer.warmZone = geometry.warmZone
        pointer.closeRect = geometry.expandedHoverRect
        // A real notch is a hole: nothing is under it, so opening the moment the
        // pointer arrives costs nothing. A synthetic one sits on a working menu
        // bar, and a pointer crossing the middle of it is usually on its way
        // somewhere else — unfolding the panel over what it was reaching for is
        // the whole complaint. Staying put is what asks for the panel.
        pointer.openDelay = geometry.isPhysical ? 0.05 : 0.3
        pointer.isDragging = { [weak root] in root?.isReceivingDrag ?? false }
        pointer.isPanelOpen = { [weak vm] in vm?.isOpen ?? false }
        pointer.onChange = { [weak self] inside in
            guard let self else { return }
            // In click mode the pointer decides nothing: it neither opens the
            // panel nor closes it, which is the whole point of the setting —
            // the panel is not to react to a pointer merely passing by.
            guard Settings.shared.opensOnHover else { return }
            self.setOpen(inside)
        }
        // Everything outside the visible panel must reach the app underneath:
        // a `nil` from hitTest only discards the event, it does not forward it.
        pointer.onInteractiveChange = { [weak self] interactive in
            self?.panel?.ignoresMouseEvents = !interactive
        }
        pointer.start()

        // Driven by the deliberate request, not by which tab is showing: a
        // hover can land on the typing tab now, and that alone must not take
        // the keyboard away from the window underneath.
        vm.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] wants in
                MainActor.assumeIsolated { self?.setKeyboard(wants) }
            }
            .store(in: &cancellables)

        // Clicking into another app drops the keyboard: there is no
        // click-outside to catch, but losing key status says the same. The tab
        // stays as it was — only the claim on the keyboard is dropped.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.viewModel?.wantsKeyboard = false
                    // A click-opened panel closes when the keyboard goes, and
                    // the keyboard goes the moment anything else is clicked.
                    // This is what a popover does, and it is the only signal
                    // that arrives reliably: a global mouse monitor hears
                    // clicks in other applications only sometimes, and never
                    // hears the ones the window server swallows.
                    guard !Settings.shared.opensOnHover, self.viewModel?.isOpen == true else { return }
                    // Unless the pointer is still on the panel. The panel gives
                    // the keyboard up by itself whenever a tab that has no
                    // field is selected — and the rail selects tabs as the
                    // pointer crosses it — so "lost the keyboard" and "the user
                    // has gone elsewhere" are not the same event. Where the
                    // pointer is settles which one this is.
                    guard let geometry = self.viewModel?.geometry,
                          !geometry.expandedHoverRect.contains(NSEvent.mouseLocation) else { return }
                    self.closeAfterClick()
                }
            }
            .store(in: &cancellables)

        vm.start()

        // A rebuilt panel starts closed. If the pointer is already sitting on
        // it, reopen at once instead of waiting for a trip back to the notch.
        if geometry.expandedHoverRect.contains(NSEvent.mouseLocation) {
            pointer.setInside(true)
            setOpen(true)
        }
    }

    // MARK: - Open / close

    /// Hands the keyboard to the panel, or gives it back.
    private func setKeyboard(_ wants: Bool) {
        if wants {
            setOpen(true)
            pointer.setInside(true)
        }
        // In click mode an open panel holds the keyboard whatever tab is
        // showing. Tabs without a field give it up on their own, and giving it
        // up there would take away both of the ways this panel closes: losing
        // key status is the signal, and Esc needs the keys.
        let holdsForClickMode = !Settings.shared.opensOnHover && viewModel?.isOpen == true
        panel?.acceptsKeyboard = wants || holdsForClickMode
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the text out. Esc and the ✕ do that.
        if !wants { scheduleCollapseIfPointerAway() }
    }

    /// The pointer decides, always. A field with something in it does not hold
    /// the panel open: it is opened by hovering, and anything that survives the
    /// pointer leaving would have to be dismissed some other way, which is a
    /// second rule to learn for a panel that has exactly one. What was typed is
    /// kept, so coming back finds it where it was left.
    private func setOpen(_ open: Bool) {
        guard let vm = viewModel, vm.isOpen != open else { return }
        openGeneration += 1
        closeActiveRectWork?.cancel()

        if open {
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            withAnimation(Theme.openAnimation) { vm.isOpen = true }
            vm.media.setActive(true)
            vm.calendar.setActive(true)
        } else {
            // The keyboard goes first and the fold goes second — one run-loop
            // pass apart, never together. Dropped in the same pass, resigning
            // the field's first responder and structurally removing that field
            // land in one transaction, and SwiftUI applies the state but loses
            // the repaint: the panel stands on screen fully expanded with
            // `isOpen` already false, wedged until the next hover repaints it.
            // That was the translate tab "hanging open" — type, move the
            // pointer away, and the picture stayed while the state closed.
            vm.wantsKeyboard = false
            let generation = openGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openGeneration == generation else { return }
                self.collapse()
            }
        }
    }

    /// What the menu bar switches. Handed out rather than wrapped: the menu
    /// reads four sections and writes them one at a time, and a controller
    /// method per section would be four methods that only forward.
    var privacy: PrivacyMode? { viewModel?.privacy }

    /// The copy history. Read through the view model only for convenience —
    /// the store itself is app-wide and survives every rebuild.
    var buffer: BufferStore? { viewModel?.buffer }

    /// The visual half of closing, one pass after the keyboard was let go.
    private func collapse() {
        guard let vm = viewModel, vm.isOpen else { return }
        stopWatchingForClickOutside()
        // Whatever was uncovered by hand goes back under cover with the panel.
        // The next hover is the one nobody planned, and it must not open onto
        // a row somebody revealed ten minutes ago.
        vm.privacy.coverEverything()
        withAnimation(Theme.openAnimation) { vm.isOpen = false }
        vm.media.setActive(false)
        vm.calendar.setActive(false)
        // Shrink only once the panel has finished collapsing. Doing it
        // while it is still visibly there would leave a window in which
        // clicks land on whatever is behind the panel.
        let work = DispatchWorkItem { [weak self] in self?.applyActiveRect(open: false) }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Re-arms an open panel for the mode it has just been switched into.
    private func modeChanged(toHover: Bool) {
        guard let vm = viewModel, vm.isOpen else {
            stopWatchingForClickOutside()
            return
        }

        if toHover {
            // The pointer is in charge again, and it decides from where it
            // actually is — not from where the watcher last recorded it.
            stopWatchingForClickOutside()
            let inside = vm.geometry.expandedHoverRect.contains(NSEvent.mouseLocation)
            pointer.setInside(inside)
            if !inside { setOpen(false) }
        } else {
            // This panel was opened by hovering, so it has none of what closes
            // a clicked one. Give it both: the keyboard, whose loss is the
            // signal that something else was clicked, and the monitor that
            // catches the clicks that make no window key at all.
            panel?.acceptsKeyboard = true
            watchForClickOutside()
        }
    }

    /// Opens the panel because the notch was clicked.
    ///
    /// Taking the keyboard is the point, not a side effect: it is what makes
    /// the panel close again when anything else is clicked. Everywhere else
    /// this app goes to great lengths *not* to take focus — but that is for a
    /// panel one merely hovers, and this one was asked for by name.
    private func openByClick() {
        guard let vm = viewModel else { return }
        pointer.setInside(true)
        setOpen(true)
        vm.wantsKeyboard = true
        watchForClickOutside()
    }

    private func closeAfterClick() {
        // Dropping the keyboard makes the panel resign key, which is the very
        // notification that brought us here — so without a latch this closes
        // itself in a circle.
        guard !isClosingAfterClick else { return }
        isClosingAfterClick = true
        defer { isClosingAfterClick = false }

        stopWatchingForClickOutside()
        viewModel?.wantsKeyboard = false
        panel?.acceptsKeyboard = false
        setOpen(false)
        pointer.setInside(false)
    }

    /// A second way home for the click-opened panel, for the case where losing
    /// key status does not happen — a click on the desktop, say, which makes
    /// no window key at all.
    ///
    /// A global monitor, which for *mouse* events needs no permission — only
    /// keyboard monitoring does. It is the only way to hear about a click in
    /// another application without taking focus, and taking focus is exactly
    /// what this panel spends its whole design avoiding.
    private func watchForClickOutside() {
        clickOutsideMonitor.map(NSEvent.removeMonitor)
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let geometry = self.viewModel?.geometry else { return }
                // A click on the panel itself arrives here too — it is global —
                // so the panel's own area is excluded by hand.
                guard !geometry.expandedHoverRect.contains(NSEvent.mouseLocation) else { return }
                self.stopWatchingForClickOutside()
                self.setOpen(false)
                self.pointer.setInside(false)
            }
        }
    }

    private func stopWatchingForClickOutside() {
        clickOutsideMonitor.map(NSEvent.removeMonitor)
        clickOutsideMonitor = nil
    }

    private func scheduleCollapseIfPointerAway() {
        // In click mode nothing collapses because the pointer wandered off.
        guard Settings.shared.opensOnHover else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let geometry = self.viewModel?.geometry else { return }
            // Resync either way. A pointer that is still on the panel has to be
            // recorded as inside, or hover tracking stays convinced it left and
            // the panel hangs open until the notch is touched again.
            let away = !geometry.expandedHoverRect.contains(NSEvent.mouseLocation)
            self.pointer.setInside(!away)
            if away { self.setOpen(false) }
        }
    }

    private func applyActiveRect(open: Bool) {
        guard let vm = viewModel, let rootView else { return }
        // Collapsed, the panel claims only its target strip — on a synthetic
        // notch that is deliberately shallower than the menu bar, so clicks on
        // status items underneath reach them instead of a panel nobody can see.
        let size = open ? vm.geometry.expandedSize : vm.geometry.collapsedSize
        var rect = vm.geometry.contentRect(for: size)
        if open {
            // Slack so the concave shoulders stay grabbable. Never while
            // collapsed: that would swallow clicks on menu bar items next to
            // the notch.
            rect = rect.insetBy(dx: -Theme.openTopRadius, dy: 0)
        }
        rootView.activeRect = rect
        pointer.interactiveRect = vm.geometry
            .contentScreenRect(for: size)
            .insetBy(dx: open ? -Theme.openTopRadius : 0, dy: 0)
    }
}

