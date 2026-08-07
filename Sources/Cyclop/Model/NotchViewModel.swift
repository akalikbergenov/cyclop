import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, buffer, snippets, calendar, translate, notes, settings
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .buffer: return "list.clipboard.fill"
            case .snippets: return "pin.fill"
            case .calendar: return "calendar"
            case .translate: return "translate"
            case .notes: return "note.text"
            case .settings: return "gearshape.fill"
            }
        }

        var title: String {
            switch self {
            case .media: return localized("Music")
            case .buffer: return localized("Buffer")
            case .snippets: return localized("Snippets")
            case .calendar: return localized("Calendar")
            case .translate: return localized("Translate")
            case .notes: return localized("Notes")
            case .settings: return localized("Settings")
            }
        }

        /// Tabs that need key presses. Landing on one hands the panel the
        /// keyboard, so that arriving and typing is a single move. Settings is
        /// here for the shortcut recorder, which has no field but is nothing
        /// without keys.
        var needsKeyboard: Bool {
            self == .translate || self == .snippets || self == .notes || self == .settings
        }

        /// Which rail the icon sits on. The left one carries what the app is
        /// for; the right one what it is set up with. Merging the shelf into
        /// the buffer freed a slot on the left, which is where the settings
        /// gear would otherwise not have fitted at all.
        static let leftRail: [Tab] = [.media, .buffer, .snippets, .calendar, .translate]
        static let rightRail: [Tab] = [.notes, .settings]
    }

    @Published var isOpen = false
    @Published var isDropTargeted = false
    @Published var tab: Tab = .media {
        didSet {
            // Opening the tab only re-checks the status. The permission prompt
            // is the user's own press on the button inside the pane: this is
            // the one permission Cyclop asks for at all, and it deserves an
            // explanation before the system dialog, not after.
            if tab == .calendar { calendar.refreshAccess() }
            // The snippets file is edited from outside the app, so it is read
            // on the way in rather than held from launch.
            if tab == .snippets { snippets.reload() }
            // Nothing is dragged out of a list nobody is looking at, and a
            // selection left behind would show as a phantom count on the way
            // back in.
            if oldValue == .buffer, tab != .buffer { buffer.clearSelection() }
            // Leaving the notes sweeps out the blank ones — they cost one
            // hover to recreate, and a trail of empty cards is the clutter a
            // scratchpad exists to avoid.
            if oldValue == .notes, tab != .notes { notes.leave() }
            // Leaving the tab that types gives the keyboard straight back.
            if !tab.needsKeyboard { wantsKeyboard = false }
        }
    }

    /// Whether the panel currently holds the keyboard.
    ///
    /// Tracked apart from `tab` because the two come apart in one direction:
    /// clicking into another app drops the claim without changing which tab is
    /// showing, so the text one was typing survives and the panel is free to
    /// collapse. Landing on a tab that types always raises it again — there is
    /// no such thing as a panel that shows a field but cannot receive a key.
    @Published var wantsKeyboard = false

    let geometry: NotchGeometry
    let media: MediaController
    /// Copies, files and pictures — one list, and one instance of it for the
    /// whole app. Everything else here is rebuilt with the panel; this is not,
    /// because rebuilding it would empty the history (and the panel is now
    /// rebuilt whenever its own size is changed).
    let buffer = BufferStore.shared
    let calendar: CalendarStore
    let translator: Translator
    let snippets: SnippetStore
    let notes: NoteStore
    /// Shared by every pane that shows something worth not showing — and by
    /// the menu bar, which switches it.
    let privacy = PrivacyMode.shared
    let settings = Settings.shared

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        self.media = MediaController()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.snippets = SnippetStore()
        self.notes = NoteStore()

        // The panel header reads through to the stores — counters, the source
        // name, the equalizer. Nested ObservableObjects do not propagate on
        // their own, so those would only refresh when something else happened
        // to redraw the view.
        //
        // Forwarded only while the panel is open. Collapsed, there is nothing
        // these redraws could change — the panel is a black shape — yet the
        // stores keep their own schedule: a track change every few minutes, a
        // copy whenever one happens, and each send re-evaluated the whole
        // view for nobody. Opening repaints from the stores directly, because
        // `isOpen` is itself @Published and its own send does that.
        //
        // The stores with a text field in their pane — the translator, the
        // snippets and the notes — are deliberately absent. They change on every
        // keystroke, and redrawing the whole panel per letter costs more than a
        // stale counter: it rebuilds the field, which drops the focus, so the
        // first letter typed is also the last one that lands. Their panes
        // observe them directly, and the header counter refreshes anyway,
        // because the list is only ever re-read on the way into the tab.
        for child in [
            media.objectWillChange,
            buffer.objectWillChange,
            calendar.objectWillChange,
        ] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isOpen || self.isDropTargeted else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        isOpen || isDropTargeted ? geometry.expandedSize : geometry.notchSize
    }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab) {
        self.tab = tab
        if tab.needsKeyboard { wantsKeyboard = true }
    }

    func start() {
        media.start()
        snippets.reload()
        // Only picks up where it left off if access was granted earlier; it
        // never prompts on its own.
        calendar.start()

    }

    func stop() {
        media.stop()
        calendar.stop()
        // Whatever was typed makes it to disk even when quitting mid-thought.
        notes.flush()
    }

    func accept(urls: [URL]) -> Bool {
        buffer.add(urls)
        tab = .buffer
        return true
    }
}
