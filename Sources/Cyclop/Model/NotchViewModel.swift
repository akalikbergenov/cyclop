import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, snippets, calendar, translate, notes
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .shelf: return "tray.full.fill"
            case .clipboard: return "list.clipboard.fill"
            case .snippets: return "pin.fill"
            case .calendar: return "calendar"
            case .translate: return "translate"
            case .notes: return "note.text"
            }
        }

        var title: String {
            switch self {
            case .media: return localized("Music")
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .snippets: return localized("Snippets")
            case .calendar: return localized("Calendar")
            case .translate: return localized("Translate")
            case .notes: return localized("Notes")
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        var needsKeyboard: Bool { self == .translate || self == .snippets || self == .notes }

        /// Which rail the icon sits on. The left one carries the original six
        /// and is full — a seventh icon would outgrow the height the panel
        /// body has — so growth continues in a second column on the right,
        /// which the scratch notes open.
        static let leftRail: [Tab] = [.media, .shelf, .clipboard, .snippets, .calendar, .translate]
        static let rightRail: [Tab] = [.notes]

        /// Persisted per-tab on/off switch, set from the menu bar. Stored as
        /// raw values so a corrupt or empty file reads as "everything on"
        /// rather than "everything off" — the panel always needs at least one
        /// way in.
        static let enabledDefaultsKey = "enabledTabs"
        static let enabledChanged = Notification.Name("com.cyclop.enabledTabsChanged")

        static var enabled: Set<Tab> {
            get {
                guard let stored = UserDefaults.standard.array(forKey: enabledDefaultsKey) as? [String] else {
                    return Set(allCases)
                }
                let set = Set(stored.compactMap(Tab.init(rawValue:)))
                return set.isEmpty ? Set(allCases) : set
            }
            set {
                UserDefaults.standard.set(newValue.map(\.rawValue), forKey: enabledDefaultsKey)
                NotificationCenter.default.post(name: enabledChanged, object: nil)
            }
        }
    }

    /// Which tabs are switched on right now — the rail only ever shows these.
    @Published private(set) var enabledTabs: Set<Tab> = Tab.enabled
    @Published var tab: Tab = Tab.leftRail.first(where: Tab.enabled.contains) ?? Tab.rightRail.first(where: Tab.enabled.contains) ?? .media {
        didSet {
            // Opening the tab only re-checks the status. The permission prompt
            // is the user's own press on the button inside the pane: this is
            // the one permission Cyclop asks for at all, and it deserves an
            // explanation before the system dialog, not after.
            if tab == .calendar { calendar.refreshAccess() }
            // The snippets file is edited from outside the app, so it is read
            // on the way in rather than held from launch.
            if tab == .snippets { snippets.reload() }
            // Leaving the notes sweeps out the blank ones — they cost one
            // hover to recreate, and a trail of empty cards is the clutter a
            // scratchpad exists to avoid.
            if oldValue == .notes, tab != .notes { notes.leave() }
        }
    }

    /// True while at least one screen's panel is expanded or receiving a
    /// drag. Set from outside by whatever is keeping track of every screen's
    /// panel — this model itself has no notion of screens. The tab is shared
    /// across every display, but a redraw is only worth anything on the one
    /// that is actually showing.
    @Published var isPanelActive = false {
        didSet {
            guard isPanelActive != oldValue else { return }
            // The tickers are global — one position bar, one countdown — so
            // they run exactly while *some* screen has something to show them
            // on, not once per open panel.
            media.setActive(isPanelActive)
            calendar.setActive(isPanelActive)
        }
    }

    let media: MediaController
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let calendar: CalendarStore
    let translator: Translator
    let snippets: SnippetStore
    let notes: NoteStore

    private var cancellables = Set<AnyCancellable>()
    private var enabledTabsObserver: Any?

    init() {
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.snippets = SnippetStore()
        self.notes = NoteStore()

        // The panel header reads through to the stores — counters, the source
        // name, the equalizer. Nested ObservableObjects do not propagate on
        // their own, so those would only refresh when something else happened
        // to redraw the view.
        //
        // Forwarded only while some panel is open. Collapsed, there is nothing
        // these redraws could change — every notch is a black shape — yet the
        // stores keep their own schedule: a track change every few minutes, a
        // copy whenever one happens, and each send re-evaluated the whole
        // view for nobody. Opening repaints from the stores directly, because
        // `isPanelActive` is itself @Published and its own send does that.
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
            shelf.objectWillChange,
            clipboard.objectWillChange,
            calendar.objectWillChange,
        ] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isPanelActive else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }

        enabledTabsObserver = NotificationCenter.default.addObserver(
            forName: Tab.enabledChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEnabledTabsChange() }
        }
    }

    /// Reacts to a change made from the menu bar while the panel may already
    /// be alive: starts or stops whatever service just flipped, and moves off
    /// a tab that just disappeared instead of leaving the panel pointed at
    /// nothing.
    private func applyEnabledTabsChange() {
        let previous = enabledTabs
        let current = Tab.enabled
        guard previous != current else { return }
        enabledTabs = current
        syncBackgroundServices(previous: previous, current: current)
        if !current.contains(tab) {
            tab = Tab.leftRail.first(where: current.contains) ?? Tab.rightRail.first(where: current.contains) ?? tab
        }
    }

    /// Only three tabs have something running behind them when nobody is
    /// looking: Music holds a helper process open, Clipboard polls the
    /// pasteboard, Calendar keeps an EventKit observer. Everything else is
    /// read fresh on the way into its tab and needs nothing stopped.
    private func syncBackgroundServices(previous: Set<Tab>, current: Set<Tab>) {
        if current.contains(.media), !previous.contains(.media) {
            media.start()
        } else if !current.contains(.media), previous.contains(.media) {
            media.stop()
        }
        if current.contains(.clipboard), !previous.contains(.clipboard) {
            clipboard.start()
        } else if !current.contains(.clipboard), previous.contains(.clipboard) {
            clipboard.stop()
        }
        if current.contains(.calendar), !previous.contains(.calendar) {
            calendar.start()
        } else if !current.contains(.calendar), previous.contains(.calendar) {
            calendar.stop()
        }
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to on: the feature is the reason the folder exists.
    static var saveClipboardImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: saveClipboardImagesKey) != nil else { return true }
        return defaults.bool(forKey: saveClipboardImagesKey)
    }

    /// Hover and click both land here. Shared across every screen: landing on
    /// a tab from one display's rail is what the notch on every other display
    /// shows too. Whether this particular screen also claims the keyboard for
    /// it is that screen's own call — see `NotchContentView`.
    func select(_ tab: Tab) {
        self.tab = tab
    }

    func start() {
        shelf.load()
        snippets.reload()

        // Screenshots reach the shelf through here whether they were taken on
        // this Mac or on a phone: a copy made on the phone arrives in the same
        // pasteboard, carried over by Continuity.
        //
        // The switch is asked by the store before it touches image data, not
        // here after the fact: turned off, a copied picture used to be encoded
        // to PNG in full just to be dropped on this doorstep — pure heat on
        // exactly the machines whose owners turned the feature off.
        clipboard.wantsImages = { Self.saveClipboardImagesEnabled }
        clipboard.onImage = { [weak self] png in
            guard let self, let url = ScreenshotVault.save(png) else { return }
            self.shelf.add([url])
            if self.enabledTabs.contains(.shelf) { self.tab = .shelf }
        }

        // Starts only what is switched on. Media, Clipboard and Calendar are
        // the ones with anything to start — see `syncBackgroundServices`.
        // Calendar in particular only picks up where it left off if access
        // was granted earlier; it never prompts on its own.
        syncBackgroundServices(previous: [], current: enabledTabs)
    }

    func stop() {
        media.stop()
        clipboard.stop()
        calendar.stop()
        // Whatever was typed makes it to disk even when quitting mid-thought.
        notes.flush()
        if let enabledTabsObserver { NotificationCenter.default.removeObserver(enabledTabsObserver) }
    }

    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
