import AppKit
import Translation

/// Apple's on-device translator, driven from the panel.
///
/// The session is not ours to create: `translationTask` hands one over and owns
/// its lifetime, so everything here is about deciding *what* to translate and
/// holding the result. `TranslatePane` supplies the session.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")

    /// Both ends are always named. Leaving the source to the framework looks
    /// tempting, but its identifier is a separate asset that is not installed
    /// either — auto-detection fails with `unableToIdentifyLanguage`, and the
    /// translation that follows hangs instead of returning an error.
    struct Route: Equatable {
        var source: Locale.Language
        var target: Locale.Language
    }

    /// Keyed by the pane's debounced task. The counter is what makes a retry of
    /// unchanged text a new request rather than a no-op.
    struct Request: Equatable {
        var text: String
        var attempt: Int
    }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    /// The failure is a missing language pack, which is a thing the user can
    /// go and fix — so the pane offers the button that takes them there.
    @Published private(set) var needsDownload = false
    /// `nil` is Auto: the pair is decided fresh from the script of whatever is
    /// typed, exactly as before this existed. Set the moment either column's
    /// menu picks a language by hand, and cleared again by picking "Auto".
    /// Not persisted — a session starts back on Auto, the pair most typing
    /// actually wants.
    @Published private(set) var manualRoute: Route?

    private var attempt = 0

    var request: Request { Request(text: input, attempt: attempt) }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var route: Route { manualRoute ?? Self.route(for: trimmed) }
    var isAuto: Bool { manualRoute == nil }

    /// Curated rather than pulled live from `LanguageAvailability`: that needs
    /// an async round trip just to draw a menu, and this covers what most
    /// people actually reach for. A language outside the list still works
    /// fine through Auto — this only limits what the menus offer by hand.
    static let supportedLanguages: [Locale.Language] = [
        english, russian,
        Locale.Language(identifier: "es"),
        Locale.Language(identifier: "fr"),
        Locale.Language(identifier: "de"),
        Locale.Language(identifier: "it"),
        Locale.Language(identifier: "pt"),
        Locale.Language(identifier: "ja"),
        Locale.Language(identifier: "ko"),
        Locale.Language(identifier: "zh-Hans"),
        Locale.Language(identifier: "ar"),
        Locale.Language(identifier: "tr"),
        Locale.Language(identifier: "uk"),
        Locale.Language(identifier: "pl"),
        Locale.Language(identifier: "nl"),
    ]

    /// Picks a language for one side by hand; the other side follows only if
    /// it would otherwise collide with it (choosing the source as the current
    /// target swaps them instead of pointing both columns the same way).
    func setSource(_ language: Locale.Language) {
        let base = route
        manualRoute = Route(source: language, target: base.target == language ? base.source : base.target)
        retry()
    }

    func setTarget(_ language: Locale.Language) {
        let base = route
        manualRoute = Route(source: base.source == language ? base.target : base.source, target: language)
        retry()
    }

    func swap() {
        let base = route
        manualRoute = Route(source: base.target, target: base.source)
        retry()
    }

    func useAutoRoute() {
        manualRoute = nil
        retry()
    }

    /// Russian goes out to English, everything else comes in to Russian.
    ///
    /// Decided by script rather than by language detection: a single word is
    /// far too short to identify reliably, and "привет" comes back as Bulgarian
    /// often enough to matter.
    static func route(for text: String) -> Route {
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return cyrillic
            ? Route(source: russian, target: english)
            : Route(source: english, target: russian)
    }

    func retry() {
        attempt += 1
    }

    func clear() {
        output = ""
        failure = nil
        needsDownload = false
    }

    func reset() {
        input = ""
        clear()
    }

    func run(_ session: TranslationSession) async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        guard let source = session.sourceLanguage, let target = session.targetLanguage else { return }

        // No language pack ships installed. `prepareTranslation()` is what asks
        // for one, but it blocks until its system prompt is answered — and that
        // prompt has nowhere to appear over a borderless panel of an app that
        // never activates, so it would hang forever. Check instead, and send
        // the user to the one place that can actually install it.
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            output = ""
            needsDownload = status == .supported
            failure = needsDownload
                ? localized("The %@ → %@ language pack is not installed.", Self.name(source), Self.name(target))
                : localized("macOS does not translate this pair of languages.")
            return
        }

        do {
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            output = response.targetText
            failure = nil
            needsDownload = false
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsDownload = false
            failure = error.localizedDescription
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    /// "Русский", "English" — for the column headers. Named in the language the
    /// panel itself is in, not in the system's: those two can differ, and a
    /// column headed in one language above a button worded in another reads as
    /// a mistake.
    static func name(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier,
              let name = Locale(identifier: appLanguage).localizedString(forLanguageCode: code) else {
            return language.languageCode?.identifier.uppercased() ?? "?"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Short code for the header badge — "EN → RU" reads at a glance where a
    /// spelled-out name would not fit in the strip.
    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier.uppercased() ?? "?"
    }

    /// System Settings → General → Language & Region, which is where the
    /// "Translation Languages…" button lives.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
