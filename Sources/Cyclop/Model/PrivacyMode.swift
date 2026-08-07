import AppKit
import Combine

/// Hides what the panel holds behind a field of drifting dots, for screens that
/// somebody else is watching.
///
/// Chosen per section rather than one switch for everything: the tabs hold
/// different things, and somebody streaming their desk may care about the
/// clipboard and not about the calendar, or the other way round. The menu still
/// offers "All" first, because that is the answer most of the time and the one
/// nobody has to think about.
///
/// The choice outlives launches — forgetting to turn covering *on* is what
/// costs something, so it must not depend on remembering.
///
/// Nothing here decides *what* is a secret. Guessing at addresses and card
/// numbers with a regular expression fails silently and tells the user about it
/// only afterwards, on the recording; covering everything in a chosen section
/// is predictable, and predictability is the feature.
@MainActor
final class PrivacyMode: ObservableObject {
    /// One instance: the menu bar switches it and the panel obeys it, and the
    /// panel is rebuilt from under both whenever its size or the display
    /// changes. A per-panel instance meant the menu's ticks and what the panel
    /// covered could come apart at exactly that moment.
    static let shared = PrivacyMode()

    enum Section: String, CaseIterable, Identifiable {
        case clipboard, snippets, calendar, notes

        var id: String { rawValue }

        /// The tab's own name — the menu and the panel must not disagree about
        /// what a section is called.
        var title: String {
            switch self {
            // The raw value stays "clipboard": it is what is already written
            // in everyone's defaults, and a section that quietly stopped
            // covering on update is the one mistake this feature cannot make.
            case .clipboard: return localized("Buffer")
            case .snippets: return localized("Snippets")
            case .calendar: return localized("Calendar")
            case .notes: return localized("Notes")
            }
        }
    }

    static let key = "privacyMode.sections"
    /// What the first version of this stored: one bool for everything. Read
    /// once, so a panel that was already covering keeps covering after an
    /// update instead of quietly opening up.
    static let legacyKey = "privacyMode"

    @Published private(set) var sections: Set<Section>

    /// What the user has uncovered by hand, by row id. Cleared whenever the
    /// panel folds: a row uncovered once must not still be uncovered the next
    /// time the panel opens, which would be exactly when nobody is looking at
    /// it and the camera is.
    @Published private(set) var revealed: Set<String> = []

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: Self.key) as? [String] {
            sections = Set(stored.compactMap(Section.init(rawValue:)))
        } else if defaults.bool(forKey: Self.legacyKey) {
            sections = Set(Section.allCases)
        } else {
            sections = []
        }
    }

    // MARK: - Sections

    /// Whether this section covers its contents at all — also what decides if
    /// the eye is offered on its rows.
    func covers(_ section: Section) -> Bool {
        sections.contains(section)
    }

    var coversAll: Bool { sections.count == Section.allCases.count }
    var coversAny: Bool { !sections.isEmpty }

    func setCovering(_ section: Section, _ on: Bool) {
        if on { sections.insert(section) } else { sections.remove(section) }
        persist()
    }

    func setCoveringAll(_ on: Bool) {
        sections = on ? Set(Section.allCases) : []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(sections.map(\.rawValue).sorted(), forKey: Self.key)
        // Kept in step so that rolling back to an older build finds the switch
        // where it left it, rather than off.
        UserDefaults.standard.set(coversAny, forKey: Self.legacyKey)
        if !coversAny { revealed.removeAll() }
    }

    // MARK: - Rows

    /// True when this particular row has to be covered right now.
    func hides(_ section: Section, _ id: String) -> Bool {
        covers(section) && !revealed.contains(id)
    }

    func reveal(_ id: String) {
        revealed.insert(id)
    }

    func toggle(_ id: String) {
        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
    }

    /// Back to covered — called when the panel folds.
    func coverEverything() {
        guard !revealed.isEmpty else { return }
        revealed.removeAll()
    }
}
