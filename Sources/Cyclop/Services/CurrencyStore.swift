import AppKit
import Foundation

/// Live exchange rates from [fawazahmed0/exchange-api](https://github.com/fawazahmed0/exchange-api).
///
/// The CDN is the primary host; Cloudflare Pages is the documented fallback.
/// Rates land once a day upstream, so this store refreshes every few hours and
/// again whenever the source currency changes — that is the base the API
/// returns rates against.
@MainActor
final class CurrencyStore: ObservableObject {
    struct Currency: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
        var displayCode: String { code.uppercased() }
    }

    /// Which amount field last drove the pair — typing on one side must not
    /// bounce back through the other and fight the caret.
    enum Side { case source, target }

    @Published private(set) var currencies: [Currency] = []
    /// Rates for `rateBase`, keyed by lowercase code: one unit of the base
    /// buys this many of the key.
    @Published private(set) var rates: [String: Double] = [:]
    @Published private(set) var rateBase = ""
    @Published private(set) var rateDate: String?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?

    @Published var sourceCode: String {
        didSet {
            guard sourceCode != oldValue else { return }
            persistPair()
            Task { await refreshRates(force: true) }
            if !suppressSideEffects { recompute(from: .source) }
        }
    }

    @Published var targetCode: String {
        didSet {
            guard targetCode != oldValue else { return }
            persistPair()
            if !suppressSideEffects { recompute(from: .source) }
        }
    }

    @Published var sourceText = "1"
    @Published var targetText = ""

    private var timer: Timer?
    private var editing: Side = .source
    /// Quiet while both ends of a swap are rewritten, so the intermediate
    /// equal-codes moment never fires a convert against the wrong rate table.
    private var suppressSideEffects = false
    private let refreshInterval: TimeInterval = 3 * 60 * 60
    private let defaults = UserDefaults.standard
    private let sourceKey = "currency.source"
    private let targetKey = "currency.target"

    private static let primaryHost = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1"
    private static let fallbackHost = "https://latest.currency-api.pages.dev/v1"

    init() {
        let savedSource = defaults.string(forKey: sourceKey)?.lowercased()
        let savedTarget = defaults.string(forKey: targetKey)?.lowercased()
        sourceCode = savedSource ?? Self.defaultSource
        targetCode = savedTarget ?? Self.defaultTarget
        if sourceCode == targetCode {
            targetCode = sourceCode == "usd" ? "eur" : "usd"
        }
    }

    /// USD out, and the Mac's own currency in — or RUB when the locale has no
    /// currency of its own worth converting against.
    private static var defaultSource: String { "usd" }
    private static var defaultTarget: String {
        let code = Locale.current.currency?.identifier.lowercased()
        if let code, code != "usd", !code.isEmpty { return code }
        return "rub"
    }

    // MARK: - Lifecycle

    func start() {
        Task { await bootstrap() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRates(force: true) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called when the tab is shown: a stale cache from hours ago is fine for
    /// a glance, but opening the tab is a good moment to ask again without
    /// waiting for the timer.
    func refreshIfNeeded() {
        Task { await refreshRates(force: false) }
    }

    // MARK: - Amounts

    func setSourceText(_ text: String) {
        editing = .source
        sourceText = text
        recompute(from: .source)
    }

    func setTargetText(_ text: String) {
        editing = .target
        targetText = text
        recompute(from: .target)
    }

    func swap() {
        let previousSource = sourceCode
        let previousSourceText = sourceText
        suppressSideEffects = true
        sourceCode = targetCode
        targetCode = previousSource
        suppressSideEffects = false
        // Keep the figure that was typed; the other side follows once rates
        // for the new source land. If they are already cached, recompute now.
        sourceText = previousSourceText
        editing = .source
        if rateBase == sourceCode {
            recompute(from: .source)
        }
    }

    func filtered(query: String) -> [Currency] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return currencies }
        return currencies.filter {
            $0.code.contains(q) || $0.name.lowercased().contains(q)
        }
    }

    func name(for code: String) -> String {
        currencies.first { $0.code == code }?.name ?? code.uppercased()
    }

    // MARK: - Networking

    private func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await loadCurrencies()
            try await loadRates(for: sourceCode)
            failure = nil
            recompute(from: editing)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refreshRates(force: Bool) async {
        if !force, rateBase == sourceCode, !rates.isEmpty { return }
        do {
            if currencies.isEmpty { try await loadCurrencies() }
            try await loadRates(for: sourceCode)
            failure = nil
            recompute(from: editing)
        } catch {
            // Keep whatever rates we already have; only surface the error when
            // there is nothing to convert with.
            if rates.isEmpty { failure = error.localizedDescription }
        }
    }

    private func loadCurrencies() async throws {
        let data = try await fetch("currencies.min.json")
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        currencies = decoded
            .map { Currency(code: $0.key.lowercased(), name: $0.value.isEmpty ? $0.key.uppercased() : $0.value) }
            .sorted {
                if $0.code == $1.code { return false }
                // Everyday fiat first, then the long tail alphabetically.
                let a = Self.pinboard.contains($0.code)
                let b = Self.pinboard.contains($1.code)
                if a != b { return a && !b }
                if a, b {
                    return Self.pinboard.firstIndex(of: $0.code)! < Self.pinboard.firstIndex(of: $1.code)!
                }
                return $0.code < $1.code
            }
        if !currencies.contains(where: { $0.code == sourceCode }) {
            sourceCode = currencies.first?.code ?? "usd"
        }
        if !currencies.contains(where: { $0.code == targetCode }) {
            targetCode = currencies.first { $0.code != sourceCode }?.code ?? "eur"
        }
    }

    private func loadRates(for base: String) async throws {
        let code = base.lowercased()
        let data = try await fetch("currencies/\(code).min.json")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let date = object?["date"] as? String
        let table = object?[code] as? [String: Any] ?? [:]
        var parsed: [String: Double] = [code: 1]
        for (key, value) in table {
            if let number = value as? Double {
                parsed[key.lowercased()] = number
            } else if let number = value as? NSNumber {
                parsed[key.lowercased()] = number.doubleValue
            }
        }
        rates = parsed
        rateBase = code
        rateDate = date
    }

    /// Tries the jsDelivr CDN first, then the Cloudflare Pages mirror the
    /// upstream README asks every client to keep as a fallback.
    private func fetch(_ endpoint: String) async throws -> Data {
        var lastError: Error?
        for host in [Self.primaryHost, Self.fallbackHost] {
            guard let url = URL(string: "\(host)/\(endpoint)") else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    // MARK: - Conversion

    private func recompute(from side: Side) {
        // Rates belong to a specific base. Stale tables from the previous
        // source must not invent a conversion.
        guard rateBase == sourceCode.lowercased(),
              let rate = rates[targetCode.lowercased()], rate > 0 else {
            return
        }
        switch side {
        case .source:
            let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                targetText = ""
                return
            }
            guard let amount = Self.parse(sourceText) else { return }
            targetText = Self.format(amount * rate)
        case .target:
            let trimmed = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                sourceText = ""
                return
            }
            guard let amount = Self.parse(targetText) else { return }
            sourceText = Self.format(amount / rate)
        }
    }

    private func persistPair() {
        defaults.set(sourceCode, forKey: sourceKey)
        defaults.set(targetCode, forKey: targetKey)
    }

    /// Currencies people actually reach for, pinned to the top of the picker.
    private static let pinboard: [String] = [
        "usd", "eur", "rub", "gbp", "cny", "jpy", "chf", "try", "kzt", "uah",
        "byn", "pln", "aed", "btc", "eth", "usdt",
    ]

    /// Accepts both "1 234,56" and "1234.56". Empty and lone separators are
    /// not numbers — the other field stays put so a mid-edit "1." does not
    /// wipe the result.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains(","), normalized.contains(".") {
            // "1,234.56" vs "1.234,56" — the rightmost separator is decimal.
            if let lastComma = normalized.lastIndex(of: ","),
               let lastDot = normalized.lastIndex(of: ".") {
                if lastComma > lastDot {
                    normalized = normalized.replacingOccurrences(of: ".", with: "")
                    normalized = normalized.replacingOccurrences(of: ",", with: ".")
                } else {
                    normalized = normalized.replacingOccurrences(of: ",", with: "")
                }
            }
        } else {
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    /// Compact enough for the panel: whole numbers stay whole, fiat keeps a
    /// couple of decimals, tiny crypto rates keep more.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let abs = abs(value)
        let fraction: Int
        if abs >= 1000 { fraction = 2 }
        else if abs >= 1 { fraction = 2 }
        else if abs >= 0.01 { fraction = 4 }
        else if abs >= 0.0001 { fraction = 6 }
        else { fraction = 8 }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fraction
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
