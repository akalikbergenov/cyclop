import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, snippets, calendar, translate, notes, posts, teleprompter, settings
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
            case .posts: return "bookmark.fill"
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
            case .notes: return localized("Notes")
            case .posts: return localized("Posts")
            case .teleprompter: return localized("Teleprompter")
            case .settings: return localized("Settings")
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        var needsKeyboard: Bool { self == .translate || self == .snippets || self == .notes || self == .posts }

        /// Which rail the icon sits on. The left one carries the original six
        /// and is full — icon height is a ceiling now, not a constant (#26,
        /// #27), so a seventh icon would not overflow the panel, but it would
        /// shrink every icon on the rail to make room, which is the same
        /// objection in a quieter voice. Growth continues in a second column
        /// on the right, which the scratch notes open. Settings joins that
        /// column rather than the content rail: it is not something to hover
        /// past on the way to a track or a calendar, so it sits last,
        /// furthest from the tabs people actually rest on.
        static let leftRail: [Tab] = [.media, .shelf, .clipboard, .snippets, .calendar, .translate]
        static let rightRail: [Tab] = [.notes, .posts, .teleprompter, .settings]
    }

    /// What every screen's panel adds up to, kept by `NotchController`: this
    /// model is shared by all of them and has no panel of its own. Plain
    /// properties, because nothing on screen reads them — a view asks its own
    /// `PanelState` about its own display.
    var isPanelActive = false
    var isTyping = false

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
            // Leaving the notes sweeps out the blank ones — they cost one
            // hover to recreate, and a trail of empty cards is the clutter a
            // scratchpad exists to avoid.
            if oldValue == .notes, tab != .notes { notes.leave() }
            // Leaving the posts commits a note that was mid-edit to disk now
            // rather than a debounce later.
            if oldValue == .posts, tab != .posts { posts.flush() }
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
    let calendar: CalendarStore
    let translator: Translator
    let snippets: SnippetStore
    let notes: NoteStore
    let teleprompter: TeleprompterStore
    let posts: PostStore
    /// Shared by every pane that shows something worth not showing.
    let privacy = PrivacyMode()

    private var cancellables = Set<AnyCancellable>()

    init() {
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.snippets = SnippetStore()
        self.notes = NoteStore()
        self.teleprompter = TeleprompterStore()
        self.posts = PostStore()

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

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to on: the feature is the reason the folder exists.
    static var saveClipboardImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: saveClipboardImagesKey) != nil else { return true }
        return defaults.bool(forKey: saveClipboardImagesKey)
    }

    func start() {
        media.start()
        shelf.load()
        snippets.reload()
        // Only picks up where it left off if access was granted earlier; it
        // never prompts on its own.
        calendar.start()

        // Screenshots reach the shelf through here whether they were taken on
        // this Mac or on a phone: a copy made on the phone arrives in the same
        // pasteboard, carried over by Continuity.
        //
        // The switch is asked by the store before it touches image data, not
        // here after the fact: turned off, a copied picture used to be encoded
        // to PNG in full just to be dropped on this doorstep — pure heat on
        // exactly the machines whose owners turned the feature off.
        clipboard.wantsImages = { Self.saveClipboardImagesEnabled }
        // Copied post links become saved posts. The switch is asked per copy,
        // not once here: turning the tab off must also stop the collecting.
        clipboard.onText = { [weak self] text in
            guard PostStore.isEnabled else { return }
            self?.posts.capture(text)
        }
        clipboard.onImage = { [weak self] png in
            guard let self, let url = ScreenshotVault.save(png) else { return }
            self.receivedScreenshot(at: url)
        }
        clipboard.start()
    }

    func stop() {
        media.stop()
        clipboard.stop()
        calendar.stop()
        // Whatever was typed makes it to disk even when quitting mid-thought.
        notes.flush()
        posts.flush()
    }

    /// A screenshot that arrived on its own — copied elsewhere, or synced
    /// from a phone by Continuity — rather than one the user handed to the
    /// panel directly. It goes on the shelf either way, but only switches to
    /// showing it when nobody is mid-sentence: the tab's own field would
    /// slide out from under the caret, and losing the keyboard mid-word sends
    /// the rest of the sentence to whatever is underneath. The shelf's
    /// counter already shows the new picture, so nothing about it is lost by
    /// waiting.
    func receivedScreenshot(at url: URL) {
        shelf.add([url])
        guard !isTyping else { return }
        tab = .shelf
    }

    /// A file the user dropped on the panel by hand — switching to the shelf
    /// is the point, not a side effect to guard against.
    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
