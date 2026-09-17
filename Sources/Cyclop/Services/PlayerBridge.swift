import AppKit

/// Public-API bridge to the two scriptable players macOS ships with support
/// for. Everything goes through AppleScript (state, artwork, transport) and
/// distributed notifications (change events) — no private frameworks.
enum PlayerApp: String, CaseIterable {
    case music, spotify

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    /// Distributed notification the player posts on every state change.
    var changeNotification: Notification.Name {
        switch self {
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct PlayerState {
    var app: PlayerApp
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var artworkURL: URL?
    /// Spotify's own id for the track, when the player reports one. It is what
    /// the oEmbed fallback below asks by, and it is absent for anything that is
    /// not a Spotify catalogue track — a local file, an ad.
    var trackID: String?
    /// Identity of the track, used to decide when artwork must be refetched.
    var key: String { "\(app.rawValue)|\(title)|\(artist)|\(album)" }
}

/// Called from the panel and answering to it: every entry point here is
/// reached from `MediaController`, and every completion is delivered back on
/// the main thread. Saying so out loud is what `.v6` asks for — the work still
/// happens on `queue` and in `URLSession`, and only the answer comes home.
@MainActor
enum PlayerBridge {
    private static let queue = DispatchQueue(label: "com.cyclop.applescript", qos: .utility)

    // MARK: - State

    static func state(of app: PlayerApp, completion: @escaping (PlayerState?) -> Void) {
        guard app.isRunning else { return completion(nil) }
        runScript(stateScript(for: app)) { descriptor in
            guard let raw = descriptor?.stringValue, !raw.isEmpty else { return completion(nil) }
            completion(parse(raw, app: app))
        }
    }

    /// Never launches a player: only already-running ones are queried, and a
    /// playing app wins over a merely-open one.
    static func currentState(completion: @escaping (PlayerState?) -> Void) {
        let candidates = PlayerApp.allCases.filter(\.isRunning)
        guard !candidates.isEmpty else { return completion(nil) }

        var results: [PlayerState] = []
        let group = DispatchGroup()
        for app in candidates {
            group.enter()
            state(of: app) { state in
                if let state { results.append(state) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(results.first(where: \.isPlaying) ?? results.first)
        }
    }

    // MARK: - Transport

    static func playPause(_ app: PlayerApp) { command("playpause", on: app) }
    static func next(_ app: PlayerApp) { command("next track", on: app) }
    static func previous(_ app: PlayerApp) {
        // Spotify's `previous track` restarts the current song first, matching
        // its own UI; Music behaves the same way. Seeking to 0 first is what
        // users expect from a "skip back" button.
        command(app == .spotify ? "set player position to 0\n    previous track" : "back track", on: app)
    }

    static func seek(_ app: PlayerApp, to seconds: TimeInterval) {
        command("set player position to \(Int(seconds))", on: app)
    }

    private static func command(_ body: String, on app: PlayerApp) {
        guard app.isRunning else { return }
        runScript("""
        tell application id "\(app.bundleID)"
            \(body)
        end tell
        """) { _ in }
    }

    /// System-wide media key, used when no scriptable player is running.
    /// Requires Accessibility permission; silently does nothing without it.
    static func postMediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags: Int = down ? 0xA00 : 0xB00
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (Int(key) << 16) | flags,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    enum MediaKey: Int32 {
        case playPause = 16, next = 17, previous = 18
    }

    // MARK: - Artwork

    /// Hosts that could not be reached at all in this session.
    ///
    /// A CDN blocked by the network does not become reachable for the next
    /// track: asking again buys nothing but the same wait on every track
    /// change, with the pane sitting on a placeholder until it times out.
    /// A 404 is not this — that is a clear answer from a live host, and says
    /// something about one track, not about the host. Forgotten on quit,
    /// because the network the app wakes up on may be another one.
    private static var unreachableHosts: Set<String> = []

    static func artwork(for state: PlayerState, completion: @escaping @MainActor (NSImage?) -> Void) {
        switch state.app {
        case .spotify:
            spotifyArtwork(for: state, completion: completion)
        case .music:
            runScript("""
            tell application id "com.apple.Music"
                if (count of artworks of current track) is 0 then return missing value
                return raw data of artwork 1 of current track
            end tell
            """) { descriptor in
                completion(cover(from: descriptor?.data))
            }
        }
    }

    /// The cover for a Spotify track, by two roads.
    ///
    /// The first is the address Spotify puts in its own scripting dictionary.
    /// It is normally right there and normally works. When it is missing, or
    /// when its CDN cannot be reached from this network — which happens, and
    /// used to leave the pane shimmering forever — the second road is
    /// Spotify's oEmbed endpoint, which answers with a thumbnail for any
    /// track URI. Both are https and both are Spotify: nobody else learns
    /// anything either way, and both stay on the scripted fallback route —
    /// the primary path still fetches nothing, as SECURITY.md promises. When
    /// neither road answers, the answer is nil, and the pane says so out loud
    /// rather than pretending something is still on its way.
    private static func spotifyArtwork(
        for state: PlayerState,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        guard let url = state.artworkURL, isReachable(url) else {
            return oEmbedArtwork(for: state, completion: completion)
        }
        download(url) { data in
            if let image = cover(from: data) { return completion(image) }
            oEmbedArtwork(for: state, completion: completion)
        }
    }

    private static func oEmbedArtwork(
        for state: PlayerState,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        guard let id = state.trackID,
              let endpoint = URL(string: "https://open.spotify.com/oembed?url=spotify:track:\(id)"),
              isReachable(endpoint) else { return completion(nil) }
        download(endpoint) { data in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumbnail = json["thumbnail_url"] as? String,
                  let url = URL(string: thumbnail), isReachable(url) else { return completion(nil) }
            download(url) { completion(cover(from: $0)) }
        }
    }

    /// A cover at its own pixel size, not at whatever resolution the file
    /// claims. Spotify's oEmbed thumbnail is 300x300 pixels tagged at 300 dpi,
    /// and `NSImage(data:)` reads that as 72x72 points — which is the number
    /// the pane then measures for squareness. `MediaController` builds covers
    /// the same way for the same reason.
    private static func cover(from data: Data?) -> NSImage? {
        guard let data, !data.isEmpty,
              let rep = NSBitmapImageRep(data: data), let bitmap = rep.cgImage else { return nil }
        return NSImage(cgImage: bitmap, size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    }

    /// Whether an address is worth trying at all. Every address here comes out
    /// of another app's scripting dictionary or out of a JSON answer, so the
    /// scheme is checked: https answers for itself through TLS, while file://
    /// or some private scheme answers to nobody.
    private static func isReachable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host else { return false }
        return !unreachableHosts.contains(host)
    }

    /// The one place on this path that touches the network, so the timeout and
    /// the bookkeeping above live here and nowhere else.
    private static func download(_ url: URL, completion: @escaping @MainActor (Data?) -> Void) {
        var request = URLRequest(url: url)
        // A cover nobody has waited six seconds for is a cover nobody wants.
        request.timeoutInterval = 6
        // Неизолировано явно — см. `NowPlayingFeed.launch`: то, какой окажется
        // изоляция без этой пометки, решает версия SDK.
        URLSession.shared.dataTask(with: request) { @Sendable data, response, error in
            // Транспортная ошибка без ответа — хост молчит или закрыт. Код
            // ответа — наоборот, признак живого хоста, и хоронить его нельзя.
            let unreachable = error != nil && response == nil
            let host = url.host
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if unreachable, let host {
                        unreachableHosts.insert(host)
                        NSLog("Cyclop: artwork host \(host) unreachable, skipping it this session")
                    }
                    completion(data)
                }
            }
        }.resume()
    }

    // MARK: - Scripts

    private static func stateScript(for app: PlayerApp) -> String {
        let sep = "set sep to character id 1"
        switch app {
        case .spotify:
            // Адрес трека спрашивается отдельным try, как и позиция: он нужен
            // одной лишь обложке и не должен уносить с собой весь ответ, если
            // какая-то сборка Spotify на него не отзовётся.
            return """
            \(sep)
            tell application id "com.spotify.client"
                try
                    set pstate to player state as text
                    set t to current track
                    try
                        set pos to (round ((player position) * 1000))
                    on error
                        set pos to 0
                    end try
                    try
                        set uri to (spotify url of t)
                    on error
                        set uri to ""
                    end try
                    return pstate & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (duration of t) & sep & pos & sep & (artwork url of t) & sep & uri
                on error
                    return ""
                end try
            end tell
            """
        case .music:
            return """
            \(sep)
            tell application id "com.apple.Music"
                try
                    set pstate to player state as text
                    set t to current track
                    try
                        set pos to (round ((player position) * 1000))
                    on error
                        set pos to 0
                    end try
                    return pstate & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (round ((duration of t) * 1000)) & sep & pos & sep & "" & sep & ""
                on error
                    return ""
                end try
            end tell
            """
        }
    }

    private static func parse(_ raw: String, app: PlayerApp) -> PlayerState? {
        let parts = raw.components(separatedBy: "\u{1}")
        guard parts.count >= 6, !parts[1].isEmpty else { return nil }
        return PlayerState(
            app: app,
            isPlaying: parts[0].lowercased() == "playing",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: (Double(parts[4]) ?? 0) / 1000,
            position: (Double(parts[5]) ?? 0) / 1000,
            artworkURL: parts.count > 6 ? URL(string: parts[6]) : nil,
            trackID: parts.count > 7 ? trackID(from: parts[7]) : nil
        )
    }

    /// `spotify url of` answers `spotify:track:<id>` for a catalogue track.
    /// Anything else — a local file, an ad, an answer we did not expect — is
    /// not an id, and nothing that is not an id is going into a URL.
    private static func trackID(from raw: String) -> String? {
        let prefix = "spotify:track:"
        guard raw.hasPrefix(prefix) else { return nil }
        let id = String(raw.dropFirst(prefix.count))
        guard !id.isEmpty, id.count <= 40,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return id
    }

    /// Shared AppleScript runner: one serial queue for every script the app sends.
    static func runScript(_ source: String, completion: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error, let code = error[NSAppleScript.errorNumber] as? Int, code != 0 {
                NSLog("Cyclop: AppleScript error \(code): \(error[NSAppleScript.errorMessage] ?? "")")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }
}
