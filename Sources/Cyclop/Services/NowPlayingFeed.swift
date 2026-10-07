import AppKit

/// Runs the Now Playing helper inside `/usr/bin/perl` and turns its stdout into
/// snapshots. See `Sources/CyclopMediaHelper/helper.m` for why perl is the host.
@MainActor
final class NowPlayingFeed {
    struct Snapshot {
        var isPlaying = false
        var title = ""
        var artist = ""
        var album = ""
        var duration: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var rate: Double = 0
        /// When `elapsed` was read. MediaRemote reports a reading, not a
        /// running clock — without this the reading cannot be aged.
        var takenAt: Date?
        /// Only present on the update where the track changed.
        var artwork: Data?
        /// Name of the app owning the session, resolved from its pid.
        var source: String?
        /// Command codes the player offers right now, or nil when the helper
        /// could not ask. Nil means unknown, not none — a browser tab with a
        /// single video offers no skip commands at all, and that is worth
        /// showing, but a missing answer is not the same as an empty one.
        var commands: Set<Int>?
        /// Process the session belongs to, as MediaRemote listed it — the
        /// session's name on the wire, and where commands for it are sent.
        var pid: pid_t = 0

        func offers(_ command: Command) -> Bool {
            commands?.contains(command.rawValue) ?? true
        }

        var isEmpty: Bool { title.isEmpty }
    }

    /// Every session the system has, read at one moment.
    struct Frame {
        var sessions: [Snapshot] = []
        /// The session macOS itself calls "now playing", or 0 for none.
        var activePID: pid_t = 0
    }

    /// Codes the per-client MediaRemote API actually answers to — read off a
    /// live session's `GetSupportedCommandsForPlayer`, not assumed from the
    /// old global enum. There is no separate toggle among them: play and
    /// pause are sent explicitly, by whichever state the caller already
    /// knows it is in.
    enum Command: Int {
        case play = 0, pause = 1, next = 4, previous = 5
    }

    var onUpdate: ((Frame) -> Void)?
    /// Raised when the helper cannot run at all, so the caller can fall back.
    var onUnavailable: (() -> Void)?
    /// Raised on the first snapshot after `onUnavailable`: the route is open
    /// again and the caller can stand its fallback down.
    var onAvailable: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var failures = 0
    private var stopped = false
    /// Whether the caller was told the route is closed and has not yet been
    /// told otherwise.
    private var reportedUnavailable = false

    /// Delays before the helper is started again after it exited, in seconds.
    /// The first two are quick: a helper that died on one bad frame is usually
    /// fine on the next. From the third on it is a crash loop — something in
    /// the current session keeps killing it — and the retries thin out to a
    /// slow poll rather than stopping. The session that kills it will end,
    /// and the pane should notice when it does. It did not, once: three aborts
    /// in four seconds on 10.09.2026, then three days of an empty pane while
    /// Music played, because the third death was read as the route being gone
    /// for the rest of the app's life.
    private static let relaunchDelays: [TimeInterval] = [2, 2, 15, 60, 300]
    /// How long to wait before looking again after the helper itself said the
    /// route is closed. Rare, and a system update can close it — or open it.
    private static let closedRouteRetry: TimeInterval = 600

    private var helperPath: String? {
        Bundle.main.path(forResource: "libcyclopmedia", ofType: "dylib")
    }

    // MARK: - Lifecycle

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        terminateHelper()
    }

    private func terminateHelper() {
        guard let process else { return }
        input = nil
        process.terminate()
        self.process = nil
    }

    private func declareUnavailable() {
        guard !reportedUnavailable else { return }
        reportedUnavailable = true
        onUnavailable?()
    }

    private func relaunch(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        guard let helperPath, FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            // Nothing to retry: the dylib is missing from the bundle or perl
            // from the system, and neither comes back while we run.
            declareUnavailable()
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [
            "-e",
            "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0x01); while (1) { sleep 3600; }",
            helperPath,
        ]

        let output = Pipe()
        let commands = Pipe()
        task.standardOutput = output
        task.standardInput = commands
        task.standardError = FileHandle.nullDevice

        // `@Sendable` здесь написан, а не выведен, и это не украшение.
        //
        // Изолировано ли замыкание, записанное внутри `@MainActor`-типа,
        // решает не этот файл, а объявление API в SDK. Наследованная изоляция
        // проверяется рантаймом в момент вызова — а зовут отсюда с приватной
        // очереди Foundation, не с главного потока, — и проверка снимает
        // процесс. Ровно так 0.8.0 падало на превью в полке и на запросе
        // доступа к календарю (#108, #111).
        //
        // Аннотации в SDK и правила вывода меняются от версии к версии: на
        // тулчейне, которым собирают релизы, они не те, что на машине, где
        // пишут код, и увидеть разницу до выпуска нельзя. Написанный явно
        // `@Sendable` эту зависимость убирает: замыкание неизолировано при
        // любом компиляторе, а единственный переход на главный актор остаётся
        // там же, где был, — внутри `Task`.
        output.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }

        task.terminationHandler = { @Sendable [weak self] finished in
            let pid = finished.processIdentifier
            Task { @MainActor in self?.handleTermination(of: pid) }
        }

        do {
            try task.run()
        } catch {
            NSLog("Cyclop: helper failed to launch: \(error.localizedDescription)")
            failures += 1
            declareUnavailable()
            relaunch(after: Self.closedRouteRetry)
            return
        }

        process = task
        input = commands.fileHandleForWriting
    }

    /// Only the exit of the helper we are running now counts. One we
    /// terminated ourselves was let go of before it exited, and so was one
    /// replaced by `stop()` and `start()` in quick succession — its exit can
    /// land after the new helper is up, and must not take that one's place.
    private func handleTermination(of pid: Int32) {
        guard !stopped, let process, process.processIdentifier == pid else { return }
        self.process = nil
        input = nil
        failures += 1
        let delay = Self.relaunchDelays[min(failures, Self.relaunchDelays.count) - 1]
        // Three straight crashes and the caller is told, so it can script the
        // players it knows meanwhile. The helper keeps being retried under
        // that: the first line it delivers again raises `onAvailable`.
        if failures >= 3 { declareUnavailable() }
        NSLog("Cyclop: helper exited (\(failures) in a row), relaunch in \(Int(delay))s")
        relaunch(after: delay)
    }

    // MARK: - Commands

    /// Commands name the session they are for. A pid of 0 leaves the choice
    /// to the helper: the session macOS considers active.
    func refresh() { write("get") }
    func send(_ command: Command, to pid: pid_t) { write("cmd \(command.rawValue) \(pid)") }
    func seek(to seconds: TimeInterval, on pid: pid_t) { write("seek \(Int(seconds)) \(pid)") }

    private func write(_ line: String) {
        guard let input, let data = (line + "\n").data(using: .utf8) else { return }
        // The helper can die between our check and the write; a broken pipe
        // would raise SIGPIPE-flavoured NSException from FileHandle.
        do {
            try input.write(contentsOf: data)
        } catch {
            NSLog("Cyclop: helper write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
        // Guard against a runaway line if the helper ever misbehaves.
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }

    /// Now Playing metadata is neither ours nor the user's: a browser tab fills
    /// it through the MediaSession API, so whoever wrote the page decides what
    /// arrives here. Text is capped and stripped of the characters that reorder
    /// a line rather than appear in it — the bidi overrides that make a title
    /// read as something else entirely. Artwork is capped before it is handed
    /// to the system image decoder.
    private static let maxTextLength = 512
    /// More sessions than anybody has open — a cap, not a limit anyone meets.
    private static let maxSessions = 8
    private static let maxArtworkBytes = 4 * 1024 * 1024
    private static let bidiControls = CharacterSet(
        charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
    )

    private static func text(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        let scalars = string.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !bidiControls.contains($0)
        }
        return String(String.UnicodeScalarView(scalars.prefix(maxTextLength)))
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if object["error"] != nil {
            // The helper just said it cannot work at all. Left alone, its perl
            // host would idle in the sleep loop for the rest of the app's life,
            // holding memory for a route that is closed (#8) — so the process
            // goes down with the route, and comes back for one more look every
            // ten minutes.
            NSLog("Cyclop: helper reports \(object["error"] ?? "error"), next look in \(Int(Self.closedRouteRetry))s")
            terminateHelper()
            declareUnavailable()
            relaunch(after: Self.closedRouteRetry)
            return
        }
        failures = 0
        if reportedUnavailable {
            reportedUnavailable = false
            onAvailable?()
        }

        var frame = Frame()
        frame.activePID = pid_t(clamping: object["active"] as? Int ?? 0)
        let sessions = object["sessions"] as? [[String: Any]] ?? []
        frame.sessions = sessions.prefix(Self.maxSessions).map(Self.snapshot(from:))
        onUpdate?(frame)
    }

    private static func snapshot(from object: [String: Any]) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.isPlaying = object["playing"] as? Bool ?? false
        snapshot.title = text(object["title"])
        snapshot.artist = text(object["artist"])
        snapshot.album = text(object["album"])
        snapshot.duration = object["duration"] as? Double ?? 0
        snapshot.elapsed = object["elapsed"] as? Double ?? 0
        snapshot.rate = object["rate"] as? Double ?? 0
        if let seconds = object["timestamp"] as? Double, seconds > 0 {
            snapshot.takenAt = Date(timeIntervalSince1970: seconds)
        }
        if let base64 = object["artwork"] as? String,
           base64.count <= maxArtworkBytes / 3 * 4 + 4,
           let artwork = Data(base64Encoded: base64), artwork.count <= maxArtworkBytes {
            snapshot.artwork = artwork
        }
        if let pid = object["pid"] as? Int, pid > 0 {
            snapshot.pid = pid_t(clamping: pid)
            snapshot.source = NSRunningApplication(processIdentifier: snapshot.pid)?.localizedName
        }
        if let codes = object["commands"] as? [Int] {
            snapshot.commands = Set(codes)
        }
        return snapshot
    }
}