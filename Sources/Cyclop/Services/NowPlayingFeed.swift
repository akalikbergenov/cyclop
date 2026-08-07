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
        /// Position **as of `stamped`**, not as of now. See `livePosition`.
        var elapsed: TimeInterval = 0
        var rate: Double = 0
        /// When the player last told the system where it was. Absent only if
        /// the record carried no timestamp, in which case `elapsed` has to be
        /// taken at face value.
        var stamped: Date?
        /// When the helper read the record, so the wait in the pipe does not
        /// get counted twice.
        var read: Date = .init()
        /// Only present on the update where the track changed.
        var artwork: Data?
        /// Name of the app owning the session, resolved from its pid.
        var source: String?
        /// Bundle id of that app — the transport uses it to decide whether the
        /// owner is a player it can script.
        var bundleID: String?

        var isEmpty: Bool { title.isEmpty }

        /// Where the playhead stands now.
        ///
        /// `elapsed` is a reading taken at `stamped` and left there; the system
        /// does not advance it, so on a track that has been playing a while it
        /// is simply wrong — 0 while the song is three minutes in. The playhead
        /// has moved by the time since that reading, scaled by the rate the
        /// player reported, and that is what the bar has to be told.
        var livePosition: TimeInterval {
            guard let stamped else { return elapsed }
            guard rate > 0 else { return elapsed }
            let age = max(0, read.timeIntervalSince(stamped))
            let value = elapsed + age * rate
            return duration > 0 ? min(value, duration) : value
        }
    }

    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5
    }

    var onUpdate: ((Snapshot) -> Void)?
    /// Raised when the helper cannot run at all, so the caller can fall back.
    var onUnavailable: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var failures = 0
    private var stopped = false

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
        input = nil
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard !stopped else { return }
        guard let helperPath, FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            onUnavailable?()
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

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        do {
            try task.run()
        } catch {
            NSLog("Cyclop: helper failed to launch: \(error.localizedDescription)")
            onUnavailable?()
            return
        }

        process = task
        input = commands.fileHandleForWriting
    }

    private func handleTermination() {
        guard !stopped else { return }
        process = nil
        input = nil
        failures += 1
        // Three straight crashes means the route is gone — perl removed, or the
        // daemon closed to platform binaries too. Let the caller fall back.
        guard failures < 3 else {
            onUnavailable?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
    }

    // MARK: - Commands

    func refresh() { write("get") }
    func send(_ command: Command) { write("cmd \(command.rawValue)") }
    func seek(to seconds: TimeInterval) { write(String(format: "seek %.3f", seconds)) }

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
            // goes down with the route, and `stopped` keeps it down.
            stop()
            onUnavailable?()
            return
        }
        failures = 0

        var snapshot = Snapshot()
        snapshot.isPlaying = object["playing"] as? Bool ?? false
        snapshot.title = Self.text(object["title"])
        snapshot.artist = Self.text(object["artist"])
        snapshot.album = Self.text(object["album"])
        snapshot.duration = object["duration"] as? Double ?? 0
        snapshot.elapsed = object["elapsed"] as? Double ?? 0
        snapshot.rate = object["rate"] as? Double ?? 0
        if let stamp = object["timestamp"] as? Double, stamp > 0 {
            snapshot.stamped = Date(timeIntervalSince1970: stamp)
        }
        if let read = object["now"] as? Double, read > 0 {
            snapshot.read = Date(timeIntervalSince1970: read)
        }
        // The size gate survives the merge: the helper feeds us over a pipe,
        // and a runaway payload should be dropped, not decoded.
        if let base64 = object["artwork"] as? String,
           base64.count <= Self.maxArtworkBytes / 3 * 4 + 4,
           let artwork = Data(base64Encoded: base64), artwork.count <= Self.maxArtworkBytes {
            snapshot.artwork = artwork
        }
        if let pid = object["pid"] as? Int, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            snapshot.source = app.localizedName
            snapshot.bundleID = app.bundleIdentifier
        }
        onUpdate?(snapshot)
    }
}
