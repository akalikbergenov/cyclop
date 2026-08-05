import AppKit
import Security

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
        /// Only present on the update where the track changed.
        var artwork: Data?
        /// Name of the app owning the session, resolved from its pid.
        var source: String?

        var isEmpty: Bool { title.isEmpty }
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
        guard Self.isTrusted(dylibAt: helperPath) else {
            NSLog("Cyclop: helper dylib does not match the sealed hash — not loading it")
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

    /// Whether the dylib is the one this build shipped.
    ///
    /// It is loaded into `/usr/bin/perl`, which is signed without library
    /// validation — the loader checks nothing at all, so anything written over
    /// the file would run inside a process the media daemon trusts. Nothing but
    /// this check stands between those two facts, and it compares the file
    /// against the hash `Scripts/bundle.sh` sealed into the app's Info.plist.
    ///
    /// Worth knowing what it is worth: against a plain swap of the file it
    /// holds, and while the build is only ad-hoc signed, someone who can also
    /// rewrite Info.plist can rewrite the expectation with it. It becomes a
    /// real boundary with a Developer ID and notarisation, where a tampered
    /// bundle no longer launches.
    private static func isTrusted(dylibAt path: String) -> Bool {
        guard let expected = (Bundle.main.object(forInfoDictionaryKey: "CyclopHelperCDHash") as? String)?
            .lowercased(), !expected.isEmpty else { return false }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data else { return false }
        return hash.map { String(format: "%02x", $0) }.joined() == expected
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
    func seek(to seconds: TimeInterval) { write("seek \(Int(seconds))") }

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

    /// Now Playing metadata is neither ours nor the user's: a browser tab
    /// fills it through the MediaSession API, so whoever wrote the page decides
    /// what arrives here. Text is capped and stripped of the characters that
    /// reorder a line rather than appear in it; artwork is capped before it is
    /// handed to the system image decoder.
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
        if let base64 = object["artwork"] as? String,
           base64.count <= Self.maxArtworkBytes / 3 * 4 + 4,
           let artwork = Data(base64Encoded: base64), artwork.count <= Self.maxArtworkBytes {
            snapshot.artwork = artwork
        }
        if let pid = object["pid"] as? Int, pid > 0 {
            snapshot.source = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
        }
        onUpdate?(snapshot)
    }
}
