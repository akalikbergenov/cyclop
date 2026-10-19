import Foundation

/// What the AI tab knows about Claude, worked out from files that are already
/// on this Mac. Nothing here touches the network or asks for a permission:
///
/// - the plan's limits come from the Claude app, which checks them itself and
///   keeps a month of readings in `plan-usage-history.json` while its menu bar
///   icon is on;
/// - spending and the running turn come from Claude Code's session logs in
///   `~/.claude/projects`, the same files `claude --resume` reads.
///
/// Pure functions only — the store around them decides when to read. Both
/// formats belong to someone else, so anything unfamiliar is skipped rather
/// than guessed at.
enum ClaudeUsage {

    // MARK: - Limits

    struct Window: Equatable, Identifiable {
        enum Kind: String, CaseIterable {
            case session, weekly, weeklyOpus, weeklySonnet
        }

        let kind: Kind
        /// 0...100, as the app recorded it.
        let usedPercent: Double
        /// When the window renews, as far as the readings place it. Nil when
        /// they do not say.
        let resetsAt: Date?

        var id: String { kind.rawValue }
    }

    struct Limits: Equatable {
        let windows: [Window]
        /// When the Claude app last wrote a reading.
        let checkedAt: Date
    }

    struct Sample: Equatable {
        let date: Date
        /// Percent used, by the file's own key for each window.
        let used: [String: Double]
    }

    private static let keys: [(key: String, kind: Window.Kind)] = [
        ("fh", .session), ("sd", .weekly), ("so", .weeklyOpus), ("sn", .weeklySonnet),
    ]
    static let sessionLength: TimeInterval = 5 * 3600
    static let weekLength: TimeInterval = 7 * 86_400

    static func historyFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// Readings oldest first, or nil for a file this reader does not know.
    static func samples(from data: Data) -> [Sample]? {
        guard data.count <= 8 << 20,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? Int, version == 1 || version == 2,
              let entries = json["samples"] as? [[String: Any]] else { return nil }
        var result: [Sample] = []
        for entry in entries {
            guard let ms = (entry["t"] as? NSNumber)?.doubleValue, ms.isFinite, ms > 0 else { continue }
            // Version 1 kept the numbers beside the time, 2 moved them under "u".
            let values = version == 1 ? entry : (entry["u"] as? [String: Any] ?? [:])
            var used: [String: Double] = [:]
            for (key, _) in keys {
                guard let number = values[key] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else { continue }
                used[key] = min(100, max(0, number.doubleValue))
            }
            result.append(Sample(date: Date(timeIntervalSince1970: ms / 1000), used: used))
        }
        return result.sorted { $0.date < $1.date }
    }

    /// The latest reading, with a renewal time for each window where the
    /// history can place one.
    ///
    /// The file keeps percentages and no dates of renewal. A session renews
    /// five hours after it began, and it began no later than the first reading
    /// of the run above zero that ends with the latest one — so that reading
    /// plus five hours is the latest it can renew. A week renews on a fixed
    /// schedule, which the last drop in the readings gives away.
    static func limits(from samples: [Sample], now: Date) -> Limits? {
        guard let latest = samples.last else { return nil }
        var windows: [Window] = []
        for (key, kind) in keys {
            guard let used = latest.used[key] else { continue }
            if kind == .session {
                // A reading older than a session says nothing about the one
                // running now.
                guard now.timeIntervalSince(latest.date) < sessionLength else { continue }
                let resets = used > 0 ? sessionStart(samples).map { $0 + sessionLength } : nil
                if let resets, resets <= now {
                    windows.append(Window(kind: kind, usedPercent: 0, resetsAt: nil))
                } else {
                    windows.append(Window(kind: kind, usedPercent: used, resetsAt: resets))
                }
            } else {
                guard var resets = weeklyRenewal(samples, key: key) else {
                    windows.append(Window(kind: kind, usedPercent: used, resetsAt: nil))
                    continue
                }
                while resets <= latest.date { resets += weekLength }
                if resets <= now {
                    // Renewed since the reading: what was spent then is gone.
                    while resets <= now { resets += weekLength }
                    windows.append(Window(kind: kind, usedPercent: 0, resetsAt: resets))
                } else {
                    windows.append(Window(kind: kind, usedPercent: used, resetsAt: resets))
                }
            }
        }
        guard !windows.isEmpty else { return nil }
        return Limits(windows: windows, checkedAt: latest.date)
    }

    /// First reading of the session's run: above zero, never falling, with no
    /// gap long enough for a session to have ended inside it.
    private static func sessionStart(_ samples: [Sample]) -> Date? {
        guard var first = samples.indices.last, (samples[first].used["fh"] ?? 0) > 0 else { return nil }
        while first > 0,
              let before = samples[first - 1].used["fh"], before > 0,
              before <= (samples[first].used["fh"] ?? 0) + 1,
              samples[first].date.timeIntervalSince(samples[first - 1].date) < sessionLength {
            first -= 1
        }
        return samples[first].date
    }

    /// The moment of the last drop. Allowances renew on the hour, so when the
    /// two readings around a drop hold an hour boundary, that is the moment.
    private static func weeklyRenewal(_ samples: [Sample], key: String) -> Date? {
        for index in samples.indices.dropFirst().reversed() {
            guard let before = samples[index - 1].used[key], let after = samples[index].used[key],
                  after + 1 < before else { continue }
            let earliest = samples[index - 1].date, latest = samples[index].date
            let hour = (earliest.timeIntervalSince1970 / 3600).rounded(.down) * 3600 + 3600
            let moment = Date(timeIntervalSince1970: hour)
            return moment <= latest ? moment : latest
        }
        return nil
    }

    // MARK: - Session logs

    struct Tokens: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        /// The part of `cacheWrite` kept for an hour, which costs more.
        var cacheWriteLong = 0
    }

    /// One reply as a log records it. Claude Code writes a reply once per
    /// content block, usage repeated on each line, so `key` is what tells
    /// the copies apart from separate replies.
    struct Reply: Equatable {
        let key: String
        let date: Date
        let model: String
        let tokens: Tokens
    }

    static func projectsFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoLock = NSLock()

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        isoLock.lock()
        defer { isoLock.unlock() }
        return iso.date(from: string)
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    /// The reply on a log line, or nil for every other kind of line. The
    /// marker is looked for before parsing: most lines are tool output, often
    /// large, and none of it needs decoding to be skipped.
    static func reply(from line: Data) -> Reply? {
        guard line.range(of: assistantMarker) != nil,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model.hasPrefix("claude-"),
              let date = date(json["timestamp"]) else { return nil }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        var tokens = Tokens()
        tokens.input = int(usage["input_tokens"])
        tokens.output = int(usage["output_tokens"])
        tokens.cacheRead = int(usage["cache_read_input_tokens"])
        tokens.cacheWrite = int(usage["cache_creation_input_tokens"])
        tokens.cacheWriteLong = int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
        let id = message["id"] as? String ?? ""
        let request = json["requestId"] as? String ?? ""
        let key = id.isEmpty && request.isEmpty ? "\(date.timeIntervalSince1970)|\(model)" : "\(id)|\(request)"
        return Reply(key: key, date: date, model: model, tokens: tokens)
    }

    // MARK: - Prices

    /// Dollars per million tokens, from Anthropic's published API prices.
    /// Spending on a subscription is what the same work would have cost on
    /// the API — the figure people mean when they ask whether the plan pays
    /// for itself. Kept in the code rather than fetched: a price list from
    /// the network would be the app's second outgoing connection.
    struct Price {
        let id: String
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
        let cacheWriteLong: Double
    }

    static let prices: [Price] = [
        Price(id: "claude-fable-5-1", input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5, cacheWriteLong: 20),
        Price(id: "claude-fable-5", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, cacheWriteLong: 20),
        Price(id: "claude-opus-5-5", input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, cacheWriteLong: 8),
        Price(id: "claude-opus-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10),
        Price(id: "claude-opus-4-8", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10),
        Price(id: "claude-opus-4-7", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10),
        Price(id: "claude-opus-4-6", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10),
        Price(id: "claude-opus-4-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10),
        Price(id: "claude-opus-4-1", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75, cacheWriteLong: 30),
        Price(id: "claude-opus-4", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75, cacheWriteLong: 30),
        Price(id: "claude-sonnet-5-5", input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5, cacheWriteLong: 4),
        Price(id: "claude-sonnet-5", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, cacheWriteLong: 4),
        Price(id: "claude-sonnet-4-6", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6),
        Price(id: "claude-sonnet-4-5", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6),
        Price(id: "claude-sonnet-4", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6),
        Price(id: "claude-3-7-sonnet", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6),
        Price(id: "claude-3-5-sonnet", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6),
        Price(id: "claude-haiku-5-5", input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125, cacheWriteLong: 0.2),
        Price(id: "claude-haiku-4-5", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25, cacheWriteLong: 2),
        Price(id: "claude-3-5-haiku", input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1, cacheWriteLong: 1.6),
    ]

    /// The longest id the model starts with, so "claude-opus-4-1-…" does not
    /// fall to "claude-opus-4" by accident of order alone. An id followed by
    /// another digit is a different version: "claude-opus-5" is not
    /// "claude-opus-5-5".
    static func price(for model: String) -> Price? {
        prices
            .filter { price in
                guard model.hasPrefix(price.id) else { return false }
                let rest = model.dropFirst(price.id.count)
                guard rest.first == "-" else { return rest.isEmpty || rest.first == "[" }
                // A date stamp after the id is the same model; a short number is
                // a later version.
                let next = rest.dropFirst().prefix { $0.isNumber }
                return next.count >= 8
            }
            .max { $0.id.count < $1.id.count }
    }

    /// API cost of one reply in dollars, or nil for a model not on the list.
    static func cost(_ tokens: Tokens, model: String) -> Double? {
        guard let price = price(for: model) else { return nil }
        let shortWrite = max(0, tokens.cacheWrite - tokens.cacheWriteLong)
        let total = Double(tokens.input) * price.input
            + Double(tokens.output) * price.output
            + Double(tokens.cacheRead) * price.cacheRead
            + Double(shortWrite) * price.cacheWrite
            + Double(tokens.cacheWriteLong) * price.cacheWriteLong
        return total / 1_000_000
    }

    // MARK: - The running turn

    /// A turn of the main conversation: the prompt that opened it, what it
    /// has produced since, and whether it is still going.
    struct Turn: Equatable {
        let start: Date
        let outputTokens: Int
        let isWorking: Bool
        let lastActivity: Date
    }

    /// The last turn in a session's log, from its lines in order.
    static func lastTurn(lines: [Data]) -> Turn? {
        var tracker = TurnTracker()
        lines.forEach { tracker.feed($0) }
        return tracker.turn
    }

    /// Follows a session's log line by line, so a file that grows is read
    /// only for what it gained.
    ///
    /// A person's prompt opens a turn. A reply that ends with `end_turn` (or
    /// any other final stop) closes it; so does an interruption, or a local
    /// command's output, which never asks the model anything. Tool results
    /// arrive inside a turn and keep it open. Subagents write into the same
    /// conversation as a sidechain: their tokens count toward the turn, their
    /// endings do not end it.
    struct TurnTracker {
        private var start: Date?
        private var working = false
        private var last: Date?
        /// Output per reply id: a reply is written once per content block,
        /// and its usage grows from one copy to the next.
        private var output: [String: Int] = [:]

        var turn: Turn? {
            guard let start, let last else { return nil }
            return Turn(start: start, outputTokens: output.values.reduce(0, +), isWorking: working, lastActivity: last)
        }

        mutating func feed(_ line: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = json["type"] as? String, type == "user" || type == "assistant" else { return }
            let date = ClaudeUsage.date(json["timestamp"])
            let sidechain = json["isSidechain"] as? Bool == true
            let message = json["message"] as? [String: Any] ?? [:]
            if type == "user" {
                guard !sidechain, json["isMeta"] as? Bool != true else { return }
                if let text = ClaudeUsage.promptText(message["content"]) {
                    if text.hasPrefix("[Request interrupted by user") || text.hasPrefix("<local-command-std") {
                        working = false
                    } else if !text.hasPrefix("<command-") && !text.hasPrefix("<local-command") {
                        start = date ?? start
                        working = true
                        output = [:]
                    }
                }
                if let date { last = date }
                return
            }
            guard start != nil else { return }
            if let date { last = date }
            if let usage = message["usage"] as? [String: Any] {
                let id = (message["id"] as? String) ?? UUID().uuidString
                output[id] = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            }
            guard !sidechain else { return }
            switch message["stop_reason"] as? String {
            case "end_turn", "stop_sequence", "max_tokens", "refusal": working = false
            case nil: break
            default: working = true
            }
        }
    }

    /// The person's own words in a user line, never a tool result.
    fileprivate static func promptText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        return blocks.first { $0["type"] as? String == "text" }?["text"] as? String
    }
}
