import AppKit
import Combine
import SwiftUI

/// The panel as it stands on one display: the window, the view, hover
/// tracking, and the open/close mechanics.
///
/// Every instance shares one `NotchViewModel` — the tab and the services are
/// the same wherever you look — and keeps its own `PanelState`, window and
/// pointer watcher, because whether *this* notch is open depends only on where
/// the pointer is on *this* screen. The watchers cost nothing to have in
/// duplicate: the pointer is on one display at a time, so at most one of them
/// is ever sampling at full rate (see `PointerWatcher.updateRate`).
@MainActor
final class NotchScreenPanel {
    let geometry: NotchGeometry
    let state: PanelState

    /// Whether a running teleprompter is holding this screen open. Set by the
    /// controller for the one screen the take was started from — see
    /// `NotchViewModel.holdsOpen` for why the exception exists at all, and
    /// `NotchController.updatePin` for why it is granted to a single screen.
    var isPinned = false

    private let vm: NotchViewModel
    private let pointer = PointerWatcher()
    private var panel: NotchPanel?
    private var rootView: NotchRootView?
    private var cancellables = Set<AnyCancellable>()
    private var closeActiveRectWork: DispatchWorkItem?
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0

    init(geometry: NotchGeometry, vm: NotchViewModel) {
        self.geometry = geometry
        self.vm = vm
        self.state = PanelState(geometry: geometry, vm: vm)
        build()
    }

    func teardown() {
        pointer.stop()
        closeActiveRectWork?.cancel()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        rootView = nil
    }

    func toggle() {
        setOpen(!state.isOpen)
        pointer.setInside(state.isOpen)
    }

    /// Same display, same notch, moved: keep the panel and everything on it.
    func setFrame(_ frame: CGRect) {
        panel?.setFrame(frame, display: false)
    }

    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    /// Collapsing also puts hover tracking back in step: nothing moved the
    /// mouse, so nothing else would have.
    func activeSpaceChanged() {
        guard state.isOpen else { return }
        // What was typed is kept — only the panel closes.
        setOpen(false)
        pointer.setInside(false)
    }

    /// A dark display has no hover to watch, so the one timer that never
    /// otherwise stops — the pointer sampler — stops with it. The panel closes
    /// too, so waking always starts from the same, folded state.
    func screensSlept() {
        setOpen(false)
        pointer.setInside(false)
        pointer.stop()
    }

    func screensWoke() {
        pointer.start()
    }

    // MARK: - Construction

    private func build() {
        let panel = NotchPanel(contentRect: geometry.windowFrame)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: geometry.windowSize))
        root.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchContentView(vm: vm, panel: state))
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        root.addSubview(hosting)

        root.onDragEntered = { [weak self] in
            guard let self else { return }
            state.select(.shelf)
            state.isDropTargeted = true
            setOpen(true)
        }
        root.onDragExited = { [weak self] in
            guard let self else { return }
            state.isDropTargeted = false
            // The pointer usually is not over the panel after a drag leaves.
            scheduleCollapseIfPointerAway()
        }
        root.onDrop = { [weak self] urls in
            guard let self else { return false }
            state.isDropTargeted = false
            let accepted = vm.accept(urls: urls)
            pointer.setInside(true)
            setOpen(true)
            scheduleCollapseIfPointerAway()
            return accepted
        }

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again.
        panel.onPress = { [weak self] in
            guard let self, vm.tab.needsKeyboard else { return }
            state.wantsKeyboard = true
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
        // Cut for the tab that will be showing, not for the standard body: the
        // tab is shared, so a screen built while the teleprompter is up opens
        // straight into a body twice as deep as the rest.
        pointer.closeRect = geometry.hoverRect(for: state.openBodySize)
        // A real notch is a hole: nothing is under it, so opening the moment the
        // pointer arrives costs nothing. A synthetic one sits on a working menu
        // bar, and a pointer crossing the middle of it is usually on its way
        // somewhere else — unfolding the panel over what it was reaching for is
        // the whole complaint. Staying put is what asks for the panel.
        pointer.openDelay = geometry.isPhysical ? 0.05 : 0.3
        pointer.isDragging = { [weak root] in root?.isReceivingDrag ?? false }
        pointer.isPanelOpen = { [weak state] in state?.isOpen ?? false }
        pointer.onChange = { [weak self] inside in
            guard let self else { return }
            // The one place the pointer does not decide — see `holdsOpen`.
            // Guarded here rather than inside `setOpen` so that the reasons
            // that are not the pointer, like the screen going to sleep, still
            // close a running teleprompter.
            if !inside, holdsOpen { return }
            setOpen(inside)
        }
        // Everything outside the visible panel must reach the app underneath:
        // a `nil` from hitTest only discards the event, it does not forward it.
        pointer.onInteractiveChange = { [weak self] interactive in
            self?.panel?.ignoresMouseEvents = !interactive
        }
        pointer.start()

        // Switching tabs can change how far down the panel reaches, and both
        // the clickable region and the region the pointer counts as "on the
        // panel" are cut from that. Left alone, the teleprompter would open to
        // its full height with only its top 208 pt alive.
        vm.$tab
            .removeDuplicates()
            .sink { [weak self] tab in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Leaving the tab that types gives the keyboard back, on
                    // whichever screen was holding it.
                    if !tab.needsKeyboard { self.state.wantsKeyboard = false }
                    guard self.state.isOpen else { return }
                    // A pass later: `openBodySize` reads `tab`, and this fires
                    // while the property is still being set.
                    DispatchQueue.main.async { self.refreshOpenRects() }
                }
            }
            .store(in: &cancellables)

        // Driven by the deliberate request, not by which tab is showing: a
        // hover can land on the typing tab now, and that alone must not take
        // the keyboard away from the window underneath.
        state.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] wants in
                MainActor.assumeIsolated { self?.setKeyboard(wants) }
            }
            .store(in: &cancellables)

        // Clicking into another app drops the keyboard: there is no
        // click-outside to catch, but losing key status says the same. The tab
        // stays as it was — only the claim on the keyboard is dropped. This is
        // also what hands the keyboard between screens: the panel that takes it
        // makes itself key, and the one that had it hears about it here.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.state.wantsKeyboard = false }
            }
            .store(in: &cancellables)

        // A fresh panel starts closed. If the pointer is already sitting on
        // it — a display just woke, or was plugged in under the cursor —
        // reopen at once instead of waiting for a trip back to the notch.
        if geometry.hoverRect(for: state.openBodySize).contains(NSEvent.mouseLocation) {
            pointer.setInside(true)
            setOpen(true)
        }
    }

    // MARK: - Open / close

    /// Whether this screen is the one a running script is pinning open.
    private var holdsOpen: Bool { isPinned && vm.holdsOpen }

    /// Hands the keyboard to the panel, or gives it back.
    private func setKeyboard(_ wants: Bool) {
        if wants {
            setOpen(true)
            pointer.setInside(true)
        }
        panel?.acceptsKeyboard = wants
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the text out. Esc and the ✕ do that.
        if !wants { scheduleCollapseIfPointerAway() }
    }

    /// The pointer decides, almost always. A field with something in it does
    /// not hold the panel open: it is opened by hovering, and anything that
    /// survives the pointer leaving has to be dismissed some other way, which
    /// is a second rule to learn for a panel that has exactly one. What was
    /// typed is kept, so coming back finds it where it was left.
    ///
    /// The teleprompter is the single exception, and it is one because it
    /// cannot be anything else: a script is read while looking at the camera,
    /// which is precisely the moment nobody is touching the trackpad. The
    /// exception is held as narrow as it goes — one tab, one screen, and only
    /// while the script is actually moving — and it is enforced where the
    /// pointer is read, not here. Everything else that closes the panel still
    /// closes it: the screen sleeping, the space changing, the display
    /// arrangement changing. A pinned teleprompter surviving any of those
    /// would be a panel stuck open on a screen nobody is looking at.
    private func setOpen(_ open: Bool) {
        guard state.isOpen != open else { return }
        // Closing ends the take, but only on the screen reading it: the pin is
        // a consequence of the script moving, so the script stops with the
        // panel it is moving on — and not with any other panel folding away.
        if !open, isPinned { vm.teleprompter.suspend() }
        openGeneration += 1
        closeActiveRectWork?.cancel()

        if open {
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            withAnimation(Theme.openAnimation) { state.isOpen = true }
        } else {
            // The keyboard goes first and the fold goes second — one run-loop
            // pass apart, never together. Dropped in the same pass, resigning
            // the field's first responder and structurally removing that field
            // land in one transaction, and SwiftUI applies the state but loses
            // the repaint: the panel stands on screen fully expanded with
            // `isOpen` already false, wedged until the next hover repaints it.
            // That was the translate tab "hanging open" — type, move the
            // pointer away, and the picture stayed while the state closed.
            state.wantsKeyboard = false
            let generation = openGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, openGeneration == generation else { return }
                collapse()
            }
        }
    }

    /// The visual half of closing, one pass after the keyboard was let go.
    private func collapse() {
        guard state.isOpen else { return }
        withAnimation(Theme.openAnimation) { state.isOpen = false }
        // Shrink only once the panel has finished collapsing. Doing it
        // while it is still visibly there would leave a window in which
        // clicks land on whatever is behind the panel.
        let work = DispatchWorkItem { [weak self] in self?.applyActiveRect(open: false) }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func scheduleCollapseIfPointerAway() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            // Resync either way. A pointer that is still on the panel has to be
            // recorded as inside, or hover tracking stays convinced it left and
            // the panel hangs open until the notch is touched again.
            let away = !geometry.hoverRect(for: state.openBodySize).contains(NSEvent.mouseLocation)
            pointer.setInside(!away)
            if away, !holdsOpen { setOpen(false) }
        }
    }

    /// Re-cuts both rects for the body currently on screen.
    private func refreshOpenRects() {
        guard state.isOpen else { return }
        applyActiveRect(open: true)
        pointer.closeRect = geometry.hoverRect(for: state.openBodySize)
    }

    private func applyActiveRect(open: Bool) {
        guard let rootView else { return }
        // Collapsed, the panel claims only its target strip — on a synthetic
        // notch that is deliberately shallower than the menu bar, so clicks on
        // status items underneath reach them instead of a panel nobody can see.
        // The open size is the current tab's, not a constant: the teleprompter
        // is taller, and a rect cut for 208 would leave the bottom half of it
        // visible but untouchable.
        let size = open ? state.openBodySize : geometry.collapsedSize
        var rect = geometry.contentRect(for: size)
        if open {
            // Slack so the concave shoulders stay grabbable. Never while
            // collapsed: that would swallow clicks on menu bar items next to
            // the notch.
            rect = rect.insetBy(dx: -Theme.openTopRadius, dy: 0)
        }
        rootView.activeRect = rect
        pointer.interactiveRect = geometry
            .contentScreenRect(for: size)
            .insetBy(dx: open ? -Theme.openTopRadius : 0, dy: 0)
    }
}
