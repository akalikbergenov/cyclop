import AppKit

/// One screen's slice of panel state — everything about the notch that is
/// particular to *this* display rather than shared across all of them.
///
/// `NotchViewModel` carries the tab and the services, the same for every
/// screen; this carries only where the pointer currently has this one open.
@MainActor
final class PanelState: ObservableObject {
    @Published var isOpen = false { didSet { onActiveChange?() } }
    @Published var isDropTargeted = false { didSet { onActiveChange?() } }
    /// Whether this screen's panel currently holds the keyboard.
    ///
    /// Tracked apart from the shared tab because the two come apart in one
    /// direction: clicking into another app drops the claim without changing
    /// which tab is showing, so the text one was typing survives and the
    /// panel is free to collapse. Landing on a tab that types always raises
    /// it again — there is no such thing as a panel that shows a field but
    /// cannot receive a key.
    @Published var wantsKeyboard = false

    let geometry: NotchGeometry

    /// Fired whenever `isOpen` or `isDropTargeted` changes, so whoever owns
    /// every screen's state can recompute the shared "is anything visible"
    /// flag without polling.
    var onActiveChange: (() -> Void)?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var isActive: Bool { isOpen || isDropTargeted }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        isActive ? geometry.expandedSize : geometry.notchSize
    }
}
