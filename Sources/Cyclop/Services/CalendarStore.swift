import AppKit
import EventKit

/// Today's meetings, and the link that joins the next one.
///
/// Access is requested only when the user first opens the calendar tab: it is
/// the one permission Cyclop needs at all, and nobody should be asked for it
/// just because the app launched.
@MainActor
final class CalendarStore: ObservableObject {
    enum Access {
        case notRequested
        case granted
        case denied
    }

    struct Meeting: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendarColor: NSColor
        let link: URL?
        let provider: String?

        var isRunning: Bool {
            let now = Date()
            return start <= now && now < end
        }

        func overlaps(_ other: Meeting) -> Bool {
            start < other.end && end > other.start
        }
    }

    /// One calendar as the picker in the status-bar menu shows it (#36).
    struct CalendarOption: Identifiable {
        let id: String
        let title: String
        let isShown: Bool
    }

    @Published private(set) var access: Access = .notRequested
    @Published private(set) var meetings: [Meeting] = []
    /// Recomputed on a timer so the countdown in the header stays honest.
    @Published private(set) var now = Date()

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: Any?
    /// Whether the panel is open. The half-minute tick serves eyes only — it
    /// keeps the countdown honest and drops meetings as they end — so it runs
    /// exactly while there are eyes.
    private var isActive = false
    /// A day-long horizon leaves the tab empty every evening, which is exactly
    /// when one wonders what tomorrow looks like. A week is still glanceable
    /// because only the next meeting gets the large treatment.
    private let horizon: TimeInterval = 7 * 24 * 3600

    var next: Meeting? {
        meetings.first { $0.end > Date() }
    }

    var upcoming: [Meeting] {
        guard let next else { return [] }
        return meetings.filter { $0.id != next.id && $0.end > Date() }
    }

    // MARK: - Lifecycle

    func start() {
        access = Self.currentAccess()
        guard access == .granted else { return }
        observe()
        reload()
    }

    func stop() {
        stopTimer()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Panel opened or closed. Opening refreshes at once — the countdown must
    /// be right on the first frame, not thirty seconds in — and starts the
    /// tick; closing stops it. Meetings still change while the panel is
    /// closed, but `EKEventStoreChanged` covers that without a clock.
    func setActive(_ active: Bool) {
        isActive = active
        guard active else { return stopTimer() }
        guard access == .granted else { return }
        tick()
        startTimer()
    }

    /// Called when the calendar tab is shown. Never prompts — it only notices
    /// that access was granted elsewhere, or since last launch.
    func refreshAccess() {
        access = Self.currentAccess()
        guard access == .granted else { return }
        observe()
        reload()
        if isActive { startTimer() }
    }

    /// Prompts. Only ever called from the button the user presses.
    func requestAccess() {
        guard Self.currentAccess() == .notRequested else {
            refreshAccess()
            return
        }
        // EventKit replies on an XPC queue.  This must remain a nonisolated
        // callback; the Task performs the only hop back to the main actor.
        store.requestFullAccessToEvents { @Sendable [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.access = granted ? .granted : .denied
                guard granted else { return }
                self.observe()
                self.reload()
                if self.isActive { self.startTimer() }
            }
        }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notRequested
        default: return .denied
        }
    }

    /// Calendars unchecked in Calendar.app's sidebar. EventKit has no public
    /// notion of this at all — "shown or not" is Calendar.app's own UI state,
    /// not calendar data, so it lives in Calendar.app's preferences instead.
    /// The identifiers there are the same ones EventKit hands out: Calendar.app
    /// and EventKit both read the same underlying calendar store.
    private static func hiddenCalendarIdentifiers() -> Set<String> {
        let stored = CFPreferencesCopyAppValue(
            "DisabledCalendars" as CFString, "com.apple.iCal" as CFString
        )
        // No key at all is the ordinary case — it means nothing is hidden.
        guard let stored else { return [] }

        // A key that is present but no longer shaped the way we read it is the
        // case worth saying out loud. This is Calendar.app's own storage, not an
        // API with a contract: the day it is restructured, this function starts
        // returning an empty set, which is indistinguishable from "nothing is
        // hidden" and quietly puts the hidden calendars back on screen. Nobody
        // files that as a bug — they just see meetings that are not theirs.
        guard let disabled = stored as? [String: [String]] else {
            NSLog("Cyclop: com.apple.iCal DisabledCalendars is no longer [String: [String]] — hidden calendars will be shown again")
            return []
        }
        return Set(disabled.values.flatMap { $0 })
    }

    private func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        // Half a minute is enough for a countdown shown in whole minutes, and
        // the generous tolerance lets the system fold the wake-up into others.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
        // Drop finished meetings without a full refetch.
        if meetings.contains(where: { $0.end <= now }) {
            meetings.removeAll { $0.end <= now }
        }
    }

    // MARK: - Loading

    func reload() {
        guard access == .granted else { return }
        let hidden = Self.hiddenCalendarIdentifiers()
        let calendars = store.calendars(for: .event)
            .filter { CalendarVisibility.isShown($0.calendarIdentifier, hiddenInSystem: hidden) }
        // EventKit treats an empty array the same as nil — "no restriction",
        // not "restrict to nothing" — so unchecking every calendar has to be
        // handled before it ever reaches the predicate, or it would silently
        // show everything, the one outcome the checkbox promised not to.
        guard !calendars.isEmpty else {
            meetings = []
            now = Date()
            return
        }
        let start = Date()
        let predicate = store.predicateForEvents(
            withStart: start,
            end: start.addingTimeInterval(horizon),
            calendars: calendars
        )
        meetings = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let link = MeetingLink.find(in: event)
                return Meeting(
                    id: event.eventIdentifier ?? "\(event.startDate.timeIntervalSince1970)-\(event.title ?? "")",
                    title: event.title ?? localized("Untitled"),
                    start: event.startDate,
                    end: event.endDate,
                    calendarColor: event.calendar.color ?? .systemBlue,
                    link: link,
                    provider: link.flatMap(MeetingLink.provider)
                )
            }
        now = Date()
    }

    /// Calendars for the status-bar picker (#36), each labelled with the pick
    /// already in effect. Empty until access is granted — the menu checks
    /// that separately and shows a hint instead.
    var calendarOptions: [CalendarOption] {
        guard access == .granted else { return [] }
        let hidden = Self.hiddenCalendarIdentifiers()
        return store.calendars(for: .event)
            .sorted { $0.title < $1.title }
            .map { calendar in
                CalendarOption(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    isShown: CalendarVisibility.isShown(calendar.calendarIdentifier, hiddenInSystem: hidden)
                )
            }
    }

    /// Flips one calendar's pick and reloads at once: the menu that changed
    /// it closes right after, so the panel has to already be showing the
    /// new answer by then.
    func setCalendarShown(_ shown: Bool, identifier: String) {
        CalendarVisibility.setShown(shown, for: identifier)
        reload()
    }

    func join(_ meeting: Meeting) {
        // Checked a second time, at the point of opening. The link comes out
        // of an event, and an event can be sent by anyone: a calendar
        // invitation needs no acquaintance, only an address.
        guard let link = meeting.link, MeetingLink.isJoinable(link) else { return }
        NSWorkspace.shared.open(link)
    }

    func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

/// Whether the panel shows a calendar, kept apart from whether Calendar.app
/// does (#36). A calendar Cyclop has never been asked about takes the answer
/// `hiddenCalendarIdentifiers()` already gives, so nothing changes for anyone
/// who never opens the picker — but once picked here, that pick holds
/// regardless of what the checkbox in Calendar.app does afterwards. Hiding a
/// calendar there and hiding it in the panel over the notch are different
/// intents: someone might keep a noisy shared calendar checked in Calendar
/// itself, for availability, while wanting only their own meetings in the
/// glance the panel gives.
enum CalendarVisibility {
    private static let key = "calendarVisibilityOverrides"

    private static var overrides: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isShown(_ identifier: String, hiddenInSystem: Set<String>) -> Bool {
        overrides[identifier] ?? !hiddenInSystem.contains(identifier)
    }

    static func setShown(_ shown: Bool, for identifier: String) {
        var current = overrides
        current[identifier] = shown
        overrides = current
    }
}

/// Finds the video call in an event. Providers put the link wherever they like:
/// Google Meet in the notes, Zoom often in the location, Teams in both.
///
/// Only links to the known hosts are ever returned, and only over https. An
/// event is not the user's own text: anyone who knows the address can put one
/// in the calendar, and whatever it carries would otherwise arrive as a button
/// that says "Join" and opens it. A meeting with an unrecognised link keeps its
/// row and loses the button — the link is still in the event, one click away in
/// Calendar, where it looks like what it is.
enum MeetingLink {
    private static let hosts = [
        "meet.google.com": "Google Meet",
        "zoom.us": "Zoom",
        "teams.microsoft.com": "Teams",
        "teams.live.com": "Teams",
        "webex.com": "Webex",
        "whereby.com": "Whereby",
        "meet.jit.si": "Jitsi",
        "discord.gg": "Discord",
        "telemost.yandex.ru": "Телемост",
    ]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func find(in event: EKEvent) -> URL? {
        let haystacks = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }
        for text in haystacks {
            if let url = firstKnownLink(in: text) { return url }
        }
        return nil
    }

    /// Everything the join button is allowed to open.
    static func isJoinable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && provider(for: url) != nil
    }

    private static func firstKnownLink(in text: String) -> URL? {
        guard let detector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url,
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased() else { continue }
            if hosts.keys.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return url }
        }
        return nil
    }

    static func provider(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return hosts.first { host == $0.key || host.hasSuffix(".\($0.key)") }?.value
    }
}
