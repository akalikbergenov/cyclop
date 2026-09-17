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
    enum Section: String, CaseIterable, Identifiable {
        case clipboard, snippets, calendar, notes

        var id: String { rawValue }

        /// The tab's own name — the menu and the panel must not disagree about
        /// what a section is called.
        var title: String {
            switch self {
            case .clipboard: return localized("Clipboard")
            case .snippets: return localized("Snippets")
            case .calendar: return localized("Calendar")
            case .notes: return localized("Notes")
            }
        }
    }

    /// What the user has uncovered by hand, by row id. Cleared whenever the
    /// panel folds: a row uncovered once must not still be uncovered the next
    /// time the panel opens, which would be exactly when nobody is looking at
    /// it and the camera is.
    @Published private(set) var revealed: Set<String> = []

    @Published private(set) var sections: Set<Section>

    /// Persisted in `config.json` (#67) — the old `UserDefaults` keys, one
    /// bool for everything and then one array of sections, were folded into
    /// it once and are no longer read here.
    init() {
        sections = Set(ConfigStore.shared.privacy.compactMap(Section.init(rawValue:)))
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
        ConfigStore.shared.privacy = sections.map(\.rawValue).sorted()
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
