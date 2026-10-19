import Foundation

/// Claude's limits, spending and the turn running right now, for the AI tab.
///
/// Everything is read from files, on a timer that runs only while the panel is
/// open: limits are a reading the Claude app took minutes ago, and spending is
/// a sum nobody needs refreshed while the panel is folded. The logs are read
/// incrementally — the first open walks a month of them, every later tick only
/// what was appended since.
@MainActor
final class ClaudeUsageStore: ObservableObject {
    struct Spending: Equatable {
        var today: Double = 0
        var week: Double = 0
        var month: Double = 0
    }

    struct Status: Equatable {
        let start: Date
        let outputTokens: Int
        /// Sessions working at once; the one shown is the latest to move.
        let sessions: Int
    }

    @Published private(set) var limits: ClaudeUsage.Limits?
    /// Whether the Claude app has ever written its limits on this Mac.
    @Published private(set) var hasHistory = false
    @Published private(set) var spending: Spending?
    @Published private(set) var status: Status?
    /// Ticks with the timer so the elapsed time and the countdowns move.
    @Published private(set) var now = Date()

    private let reader = ClaudeLogReader()
    private var timer: Timer?
    private var isRunning = false
    private var isActive = false
    private var reading = false

    func start() {
        isRunning = true
        updateTimer()
    }

    /// The tab left the rail: the timer goes, and so does everything read so
    /// far, which is the only memory this tab holds.
    func stop() {
        isRunning = false
        updateTimer()
        reader.reset()
        spending = nil
        status = nil
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard isRunning, isActive else { return }
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        now = Date()
        // A first scan of a month of logs can outlast a tick; ticks that land
        // meanwhile are dropped rather than queued behind it.
        guard !reading else { return }
        reading = true
        let reader = reader
        let firstRead = spending == nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // The first walk through a month of logs takes seconds; the limits
            // are one small file and go up before it.
            if firstRead {
                let limits = ClaudeLogReader.limits(now: Date())
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning else { return }
                        self.hasHistory = limits.hasHistory
                        self.limits = limits.limits
                    }
                }
            }
            let result = reader.read(now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    guard self.isRunning else { return }
                    self.hasHistory = result.hasHistory
                    self.limits = result.limits
                    self.spending = result.spending
                    self.status = result.status
                }
            }
        }
    }
}

/// The reading half of the store, confined to whichever thread calls `read` —
/// one at a time, which the store's `reading` flag guarantees.
final class ClaudeLogReader: @unchecked Sendable {
    struct Result {
        var hasHistory = false
        var limits: ClaudeUsage.Limits?
        var spending = ClaudeUsageStore.Spending()
        var status: ClaudeUsageStore.Status?
    }

    private struct FileState {
        var offset: UInt64 = 0
        var tracker: ClaudeUsage.TurnTracker?
    }

    /// How far back spending reaches.
    private static let horizon: TimeInterval = 30 * 86_400
    /// A turn whose log has been quiet this long is not working, whatever its
    /// last line says: a session killed mid-turn never writes the ending.
    private static let idleTurn: TimeInterval = 10 * 60
    /// A session that turns active with no tracker yet is read from this far
    /// back to find the prompt that opened its turn.
    private static let tailBytes: UInt64 = 4 << 20

    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private var replies: [String: (date: Date, cost: Double)] = [:]

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        files = [:]
        replies = [:]
    }

    func read(now: Date) -> Result {
        lock.lock()
        defer { lock.unlock() }
        var result = Result()
        (result.hasHistory, result.limits) = Self.limits(now: now)

        var turns: [ClaudeUsage.Turn] = []
        for (path, modified) in logs(since: now.addingTimeInterval(-Self.horizon)) {
            let active = now.timeIntervalSince(modified) < Self.idleTurn
            var state = files[path] ?? FileState()
            if active, state.tracker == nil {
                state.tracker = tailTracker(path: path, upTo: state.offset)
            }
            consume(path: path, state: &state)
            if !active { state.tracker = nil }
            files[path] = state
            if let turn = state.tracker?.turn, turn.isWorking { turns.append(turn) }
        }

        let monthAgo = now.addingTimeInterval(-Self.horizon)
        replies = replies.filter { $0.value.date >= monthAgo }
        let today = Calendar.current.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        for reply in replies.values {
            result.spending.month += reply.cost
            if reply.date >= weekAgo { result.spending.week += reply.cost }
            if reply.date >= today { result.spending.today += reply.cost }
        }

        if let latest = turns.max(by: { $0.lastActivity < $1.lastActivity }) {
            result.status = .init(start: latest.start, outputTokens: latest.outputTokens, sessions: turns.count)
        }
        return result
    }

    static func limits(now: Date) -> (hasHistory: Bool, limits: ClaudeUsage.Limits?) {
        guard let data = try? Data(contentsOf: ClaudeUsage.historyFile()) else { return (false, nil) }
        return (true, ClaudeUsage.samples(from: data).flatMap { ClaudeUsage.limits(from: $0, now: now) })
    }

    /// Every session log touched since `date`, subagents' included: their
    /// replies are billed like any other.
    private func logs(since date: Date) -> [(String, Date)] {
        let root = ClaudeUsage.projectsFolder()
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [(String, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= date else { continue }
            found.append((url.path, modified))
        }
        return found
    }

    /// Reads what the log gained since the last look. Only whole lines are
    /// taken: the one Claude Code is in the middle of writing waits for the
    /// next tick.
    private func consume(path: String, state: inout FileState) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        // Shorter than what was read: the file was rewritten, start over.
        if size < state.offset { state.offset = 0 }
        guard size > state.offset else { return }
        try? handle.seek(toOffset: state.offset)
        guard let chunk = try? handle.readToEnd(), let lastNewline = chunk.lastIndex(of: 0x0A) else { return }
        let whole = chunk[chunk.startIndex...lastNewline]
        state.offset += UInt64(whole.count)
        for line in whole.split(separator: 0x0A) {
            let line = Data(line)
            if let reply = ClaudeUsage.reply(from: line), replies[reply.key] == nil,
               let cost = ClaudeUsage.cost(reply.tokens, model: reply.model) {
                replies[reply.key] = (reply.date, cost)
            }
            state.tracker?.feed(line)
        }
    }

    /// The turn as it stood at `offset`, from the tail before it.
    private func tailTracker(path: String, upTo offset: UInt64) -> ClaudeUsage.TurnTracker {
        var tracker = ClaudeUsage.TurnTracker()
        guard offset > 0, let handle = FileHandle(forReadingAtPath: path) else { return tracker }
        defer { try? handle.close() }
        let from = offset > Self.tailBytes ? offset - Self.tailBytes : 0
        try? handle.seek(toOffset: from)
        guard let chunk = try? handle.read(upToCount: Int(offset - from)) else { return tracker }
        var lines = chunk.split(separator: 0x0A)
        // Started mid-line unless it started at the top.
        if from > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines { tracker.feed(Data(line)) }
        return tracker
    }
}
