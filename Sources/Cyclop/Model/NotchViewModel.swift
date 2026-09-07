import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, snippets, calendar, translate, currency, notes, teleprompter, settings
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .shelf: return "tray.full.fill"
            case .clipboard: return "list.clipboard.fill"
            case .snippets: return "pin.fill"
            case .calendar: return "calendar"
            case .translate: return "translate"
            case .currency: return "dollarsign.circle"
            case .notes: return "note.text"
            case .teleprompter: return "text.viewfinder"
            case .settings: return "gearshape.fill"
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
            case .currency: return localized("Currency")
            case .notes: return localized("Notes")
            case .teleprompter: return localized("Teleprompter")
            case .settings: return localized("Settings")
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        var needsKeyboard: Bool {
            self == .translate || self == .currency || self == .snippets || self == .notes
        }

        /// Every tab can be taken off the rail except the one the switches
        /// live on: with Settings gone there would be no way back.
        var canHide: Bool { self != .settings }

        /// Which rail the icon sits on. The left one carries the original six
        /// and is full — icon height is a ceiling now, not a constant (#26,
        /// #27), so a seventh icon would not overflow the panel, but it would
        /// shrink every icon on the rail to make room, which is the same
        /// objection in a quieter voice. Growth continues in a second column
        /// on the right, which the scratch notes open: they are the daily tab
        /// of that column, so they sit where the pointer lands first. The rare
        /// modes — the converter, the teleprompter — come after them, by the
        /// rule from #43 that the rail is ordered by how often a tab is
        /// glanced at. Settings joins that column rather than the content
        /// rail: it is not something to hover past on the way to a track or a
        /// calendar, so it sits last, furthest from the tabs people actually
        /// rest on.
        static let leftRail: [Tab] = [.media, .shelf, .clipboard, .snippets, .calendar, .translate]
        static let rightRail: [Tab] = [.notes, .currency, .teleprompter, .settings]
    }

    /// What every screen's panel adds up to, kept by `NotchController`: this
    /// model is shared by all of them and has no panel of its own. Plain
    /// properties, because nothing on screen reads them — a view asks its own
    /// `PanelState` about its own display.
    private(set) var isPanelActive = false
    var isTyping = false

    // MARK: - Which tabs are on the rail

    /// Tabs switched off in Settings. The rail is for what gets a glance
    /// between other things, and a mode used once a month may live there only
    /// if the people who never use it can take it off (#43). Off means two
    /// things, and the second is what makes the switch worth having: the icon
    /// leaves the rail, and the tab's background work stops with it — the
    /// clipboard poll, the calendar watch, the Now Playing helper. A hidden
    /// tab costs nothing, or it is not hidden.
    ///
    /// Kept as the set of what is off rather than what is on, so a tab added
    /// in a later version shows up for everyone instead of arriving hidden.
    /// Persisted in `config.json` (#67), alongside the rest of what makes
    /// sense on another Mac.
    @Published private(set) var hiddenTabs: Set<Tab> = NotchViewModel.loadHiddenTabs()

    private static func loadHiddenTabs() -> Set<Tab> {
        let raw = ConfigStore.shared.hiddenTabs
        return Set(raw.compactMap(Tab.init(rawValue:))).filter(\.canHide)
    }

    func isVisible(_ tab: Tab) -> Bool { !hiddenTabs.contains(tab) }

    /// The rails as they stand with the switches applied.
    var leftRail: [Tab] { Tab.leftRail.filter(isVisible) }
    var rightRail: [Tab] { Tab.rightRail.filter(isVisible) }

    /// Where to land when the tab on screen is the one being taken away.
    private var firstVisibleTab: Tab { leftRail.first ?? rightRail.first ?? .settings }

    func setVisible(_ target: Tab, _ visible: Bool) {
        guard target.canHide, isVisible(target) != visible else { return }
        if visible {
            hiddenTabs.remove(target)
            if started { startBackground(of: target) }
        } else {
            hiddenTabs.insert(target)
            stopBackground(of: target)
            // Done before the icon goes, so the pane never shows a tab the rail
            // no longer has — and `tab`'s own didSet handles what leaving it
            // means, the teleprompter's suspend included.
            if tab == target { tab = firstVisibleTab }
        }
        ConfigStore.shared.hiddenTabs = hiddenTabs.map(\.rawValue).sorted()
    }

    /// What a tab keeps running while nobody is looking at it. Only a few have
    /// anything: the rest are a file read on the way in, or a field. Currency
    /// is one of them — its timer must not keep asking the network after the
    /// icon has left the rail.
    private func startBackground(of target: Tab) {
        switch target {
        case .media:
            media.start()
            if isPanelActive { media.setActive(true) }
        case .clipboard:
            clipboard.start()
        case .calendar:
            // Only picks up where it left off if access was granted earlier;
            // it never prompts on its own.
            calendar.start()
            if isPanelActive { calendar.setActive(true) }
        case .shelf:
            // Off until the user grants a folder through `requestAccess`;
            // this only re-arms a watch already approved on a previous launch.
            screenshotFolder.resumeIfEnabled()
        case .currency:
            currencies.start()
        case .snippets, .translate, .notes, .teleprompter, .settings:
            break
        }
    }

    private func stopBackground(of target: Tab) {
        switch target {
        case .media: media.stop()
        case .clipboard: clipboard.stop()
        case .calendar: calendar.stop()
        case .shelf: screenshotFolder.stop()
        case .currency: currencies.stop()
        case .snippets, .translate, .notes, .teleprompter, .settings: break
        }
    }

    /// Whether any screen shows more than the bare notch. The stores whose
    /// clocks exist only for an open panel — the position ticker, the meeting
    /// countdown — follow this, and only for the tabs that are on the rail.
    func setPanelActive(_ active: Bool) {
        guard active != isPanelActive else { return }
        isPanelActive = active
        if isVisible(.media) { media.setActive(active) }
        if isVisible(.calendar) { calendar.setActive(active) }
    }

    private var started = false

    /// Whether a click into the panel should hand it the keyboard. The tabs
    /// that type always do. The teleprompter does only while it has nothing to
    /// read: an empty script is shown as an editor, and an editor a click
    /// cannot put a caret into is the field from #53 all over again — the
    /// hover request on arrival is one chance, and a click has to be the
    /// second. With a script in it the tab is read, not written, and a click
    /// on play must not dim the caret of the window underneath.
    var clickTakesKeyboard: Bool {
        tab.needsKeyboard || (tab == .teleprompter && teleprompter.script.isEmpty)
    }

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
            // Same reason, sharper stakes: the shelf can hold files inside the
            // folders macOS guards, and looking at one raises a permission
            // prompt. It is asked here, with the shelf on screen, rather than
            // at launch with nothing to explain it.
            if tab == .shelf { shelf.refreshFromDisk() }
            // Rates update on a timer already; opening the tab asks once more
            // so a stale cache from the last few hours does not sit there.
            if tab == .currency { currencies.refreshIfNeeded() }
            // Leaving the notes sweeps out the blank ones — they cost one
            // hover to recreate, and a trail of empty cards is the clutter a
            // scratchpad exists to avoid.
            if oldValue == .notes, tab != .notes { notes.leave() }
            // Leaving the tab that types gives the keyboard straight back —
            // done per screen, where the claim lives, in `NotchScreenPanel`.

            // Leaving the teleprompter stops the scroll and drops the pin, so
            // the panel goes back to obeying the pointer like everything else.
            if oldValue == .teleprompter, tab != .teleprompter { teleprompter.suspend() }
        }
    }

    /// Whether the panel must stay open with no pointer on it.
    ///
    /// This is the one exception to the rule stated at `NotchController.setOpen`
    /// — the pointer decides, always — and it exists because the teleprompter
    /// cannot work under that rule: the whole point is reading while looking at
    /// the camera, hands nowhere near the trackpad. The exception is kept as
    /// narrow as it can be. It applies to one tab, only while the script is
    /// actually moving, and it ends three ways that need no explaining: the
    /// script runs out, Escape, or a click anywhere outside the panel.
    var holdsOpen: Bool { tab == .teleprompter && teleprompter.isRunning }

    let media: MediaController
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let screenshotFolder: ScreenshotFolderWatcher
    let calendar: CalendarStore
    let translator: Translator
    let currencies: CurrencyStore
    let snippets: SnippetStore
    let notes: NoteStore
    let teleprompter: TeleprompterStore
    /// Shared by every pane that shows something worth not showing.
    let privacy = PrivacyMode()

    private var cancellables = Set<AnyCancellable>()

    init() {
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.screenshotFolder = ScreenshotFolderWatcher()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.currencies = CurrencyStore()
        self.snippets = SnippetStore()
        self.notes = NoteStore()
        self.teleprompter = TeleprompterStore()

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
        // currency converter, the snippets and the notes — are deliberately
        // absent. They change on every keystroke, and redrawing the whole
        // panel per letter costs more than a stale counter: it rebuilds the
        // field, which drops the focus, so the first letter typed is also the
        // last one that lands. Their panes observe them directly, and the
        // header counter refreshes anyway, because the list is only ever
        // re-read on the way into the tab.
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
    }

    /// Off switch for people who copy images all day and do not want them
    /// kept. Persisted in `config.json` (#67) — see
    /// `ConfigStore.saveClipboardImages` for the default.
    static var saveClipboardImagesEnabled: Bool {
        get { ConfigStore.shared.saveClipboardImages }
        set { ConfigStore.shared.saveClipboardImages = newValue }
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
            self.receivedScreenshot(at: url)
        }

        // Same destination as a clipboard screenshot, and the same reason:
        // confirmation that the shot actually landed.
        screenshotFolder.onImage = { [weak self] url in
            guard let self else { return }
            self.receivedScreenshot(at: url)
        }

        // The background of every tab that is on the rail, and of no other.
        started = true
        for target in Tab.allCases where isVisible(target) { startBackground(of: target) }
        // The default tab may have been switched off in a previous session.
        if !isVisible(tab) { tab = firstVisibleTab }
    }

    func stop() {
        started = false
        for target in Tab.allCases { stopBackground(of: target) }
        // Whatever was typed makes it to disk even when quitting mid-thought.
        notes.flush()
    }

    /// A screenshot that arrived on its own — copied elsewhere, or synced
    /// from a phone by Continuity — rather than one the user handed to the
    /// panel directly. It goes on the shelf either way, but only switches to
    /// showing it when nobody is mid-sentence: the tab's own field would
    /// slide out from under the caret, and losing the keyboard mid-word sends
    /// the rest of the sentence to whatever is underneath. The shelf's
    /// counter already shows the new picture, so nothing about it is lost by
    /// waiting.
    ///
    /// With the shelf switched off the file is still kept — the folder it was
    /// saved to is the user's, and the card will be there when the shelf is
    /// back — but the panel does not jump to a tab that is not on the rail.
    func receivedScreenshot(at url: URL) {
        shelf.add([url])
        guard !isTyping, isVisible(.shelf) else { return }
        tab = .shelf
    }

    /// A file the user dropped on the panel by hand — switching to the shelf
    /// is the point, not a side effect to guard against. Refused when the
    /// shelf is off: a drop that lands nowhere visible is worse than one that
    /// bounces.
    func accept(urls: [URL]) -> Bool {
        guard isVisible(.shelf) else { return false }
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
