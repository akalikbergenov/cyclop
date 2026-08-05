import AppKit
import Combine
import SwiftUI

/// Everything needed to show and drive the panel on one screen: the AppKit
/// window, the hosting view, hover tracking, and the open/close mechanics.
///
/// Every instance shares one `NotchViewModel` — the tab and the services are
/// the same everywhere — but keeps its own `PanelState`, pointer watcher and
/// window, because whether *this* notch is open depends only on where the
/// pointer is on *this* screen.
@MainActor
final class NotchScreenPanel {
    let geometry: NotchGeometry
    let state: PanelState

    private let vm: NotchViewModel
    private let pointer = PointerWatcher()
    private var panel: NotchPanel?
    private var rootView: NotchRootView?
    private var cancellables = Set<AnyCancellable>()
    private var closeActiveRectWork: DispatchWorkItem?
    private var openGeneration = 0

    init(geometry: NotchGeometry, vm: NotchViewModel) {
        self.geometry = geometry
        self.vm = vm
        self.state = PanelState(geometry: geometry)
        build()
    }

    func teardown() {
        pointer.stop()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        rootView = nil
        cancellables.removeAll()
        closeActiveRectWork?.cancel()
    }

    /// This screen's window belongs to the desktop it opened on; ⌘-Tab to
    /// another space leaves the pointer wherever it happened to be — not a
    /// reason to keep this screen's panel expanded.
    func handleActiveSpaceChanged() {
        guard state.isOpen else { return }
        setOpen(false)
        pointer.setInside(false)
    }

    /// A dark display has no hover to watch, so the sampler stops with it.
    func handleScreensSlept() {
        setOpen(false)
        pointer.setInside(false)
        pointer.stop()
    }

    func handleScreensWoke() {
        pointer.start()
    }

    func setFrame(_ frame: CGRect) {
        panel?.setFrame(frame, display: false)
    }

    func toggle() {
        setOpen(!state.isOpen)
        pointer.setInside(state.isOpen)
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
            guard let self, self.vm.enabledTabs.contains(.shelf) else { return }
            self.vm.tab = .shelf
            self.state.isDropTargeted = true
            self.setOpen(true)
        }
        root.onDragExited = { [weak self] in
            guard let self else { return }
            self.state.isDropTargeted = false
            // The pointer usually is not over the panel after a drag leaves.
            self.scheduleCollapseIfPointerAway()
        }
        root.onDrop = { [weak self] urls in
            guard let self, self.vm.enabledTabs.contains(.shelf) else { return false }
            self.state.isDropTargeted = false
            let accepted = self.vm.accept(urls: urls)
            self.pointer.setInside(true)
            self.setOpen(true)
            self.scheduleCollapseIfPointerAway()
            return accepted
        }

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again.
        panel.onPress = { [weak self] in
            guard let self, self.vm.tab.needsKeyboard else { return }
            self.state.wantsKeyboard = true
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
        pointer.isDragging = { [weak root] in root?.isReceivingDrag ?? false }
        pointer.isPanelOpen = { [weak self] in self?.state.isOpen ?? false }
        pointer.onChange = { [weak self] inside in
            self?.setOpen(inside)
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
        state.$wantsKeyboard
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
                MainActor.assumeIsolated { self?.state.wantsKeyboard = false }
            }
            .store(in: &cancellables)

        // A freshly built panel starts closed. If the pointer is already
        // sitting on it, reopen at once instead of waiting for a trip back.
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
        panel?.acceptsKeyboard = wants
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the text out. Esc and the ✕ do that.
        if !wants { scheduleCollapseIfPointerAway() }
    }

    /// The pointer decides, always. See `NotchController` for the fuller
    /// version of this reasoning — it applies per screen exactly as it used
    /// to apply to the one panel there used to be.
    private func setOpen(_ open: Bool) {
        guard state.isOpen != open else { return }
        openGeneration += 1
        closeActiveRectWork?.cancel()

        if open {
            applyActiveRect(open: true)
            withAnimation(Theme.openAnimation) { state.isOpen = true }
        } else {
            state.wantsKeyboard = false
            let generation = openGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openGeneration == generation else { return }
                self.collapse()
            }
        }
    }

    private func collapse() {
        guard state.isOpen else { return }
        withAnimation(Theme.openAnimation) { state.isOpen = false }
        let work = DispatchWorkItem { [weak self] in self?.applyActiveRect(open: false) }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func scheduleCollapseIfPointerAway() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let away = !self.geometry.expandedHoverRect.contains(NSEvent.mouseLocation)
            self.pointer.setInside(!away)
            if away { self.setOpen(false) }
        }
    }

    private func applyActiveRect(open: Bool) {
        guard let rootView else { return }
        let size = open ? geometry.expandedSize : geometry.notchSize
        var rect = geometry.contentRect(for: size)
        if open {
            rect = rect.insetBy(dx: -Theme.openTopRadius, dy: 0)
        }
        rootView.activeRect = rect
        pointer.interactiveRect = geometry
            .contentScreenRect(for: size)
            .insetBy(dx: open ? -Theme.openTopRadius : 0, dy: 0)
    }
}
