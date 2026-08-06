import AppKit

/// A player the app can address directly — ask where it stands, tell it what
/// to do — instead of trusting the system's Now Playing record, which on
/// current macOS is neither current nor commandable (see `MediaController`).
///
/// The record still *discovers* sessions: it is the only thing that sees
/// browser tabs and everything else. A connector is what makes a session
/// exact once the record names an owner we know how to talk to. Adding a
/// player is one conforming type plus a line in `PlayerConnectors.all`.
@MainActor
protocol PlayerConnector {
    /// Matched against the bundle id of the app owning the Now Playing session.
    /// Nonisolated: identity is immutable and read from value types like
    /// `PlayerState.key` that carry no actor context of their own.
    nonisolated var bundleID: String { get }
    nonisolated var displayName: String { get }
    /// Distributed notification the player posts on every state change; the
    /// no-helper fallback listens to these instead of polling blind.
    var changeNotification: Notification.Name { get }

    func state(completion: @escaping (PlayerState?) -> Void)
    func playPause()
    func next()
    func previous()
    func seek(to seconds: TimeInterval)
    func artwork(for state: PlayerState, completion: @escaping (NSImage?) -> Void)
    /// True when no route to a cover exists for this track at all, so the
    /// caller can settle for a placeholder at once instead of retrying a fetch
    /// that cannot succeed. Defaults to false.
    func artworkIsUnobtainable(for state: PlayerState) -> Bool
}

extension PlayerConnector {
    func artworkIsUnobtainable(for state: PlayerState) -> Bool { false }
}

struct PlayerState {
    let connector: any PlayerConnector
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var artworkURL: URL?
    /// The player's own id for the track, when it has one — the way back to
    /// artwork when `artworkURL` is not (see `SpotifyConnector.artwork`).
    var trackID: String?
    /// Identity of the track, used to decide when artwork must be refetched.
    var key: String { "\(connector.bundleID)|\(title)|\(artist)|\(album)" }
}

extension PlayerConnector {
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Sends a transport command; never launches the player to do it.
    func command(_ body: String) {
        guard isRunning else { return }
        PlayerBridge.runScript("""
        tell application id "\(bundleID)"
            \(body)
        end tell
        """) { _ in }
    }

    func seek(to seconds: TimeInterval) {
        // Players take a real here. Rounding to the second would put the
        // playhead up to half a second from where the cursor was let go, which
        // on a short track is a visible distance along the bar.
        command(String(format: "set player position to %.3f", seconds))
    }

    /// Runs a state script and parses its answer. Both bundled connectors emit
    /// the same sep-separated shape — state, name, artist, album, duration in
    /// ms, position in ms, artwork url, track id — so the parsing lives here.
    func runStateScript(_ source: String, completion: @escaping (PlayerState?) -> Void) {
        guard isRunning else { return completion(nil) }
        PlayerBridge.runScript(source) { descriptor in
            guard let raw = descriptor?.stringValue, !raw.isEmpty else { return completion(nil) }
            completion(parseState(raw))
        }
    }

    private func parseState(_ raw: String) -> PlayerState? {
        let parts = raw.components(separatedBy: "\u{1}")
        guard parts.count >= 6, !parts[1].isEmpty else { return nil }
        // AppleScript folds `missing value` into the concatenation as those two
        // literal words, and lenient URL parsing would happily wrap them into a
        // URL and send a doomed request. Only an actual address counts.
        var artworkURL: URL?
        if parts.count > 6, parts[6].hasPrefix("http") { artworkURL = URL(string: parts[6]) }
        return PlayerState(
            connector: self,
            isPlaying: parts[0].lowercased() == "playing",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: (Double(parts[4]) ?? 0) / 1000,
            position: (Double(parts[5]) ?? 0) / 1000,
            artworkURL: artworkURL,
            trackID: parts.count > 7 && !parts[7].isEmpty ? parts[7] : nil
        )
    }
}

/// The players Cyclop knows how to talk to.
@MainActor
enum PlayerConnectors {
    static let all: [any PlayerConnector] = [MusicConnector(), SpotifyConnector()]

    static func match(bundleID: String?) -> (any PlayerConnector)? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleID == bundleID }
    }

    /// Asks every running player at once; a playing one wins over a merely
    /// open one. Never launches anything.
    static func currentState(completion: @escaping (PlayerState?) -> Void) {
        let candidates = all.filter(\.isRunning)
        guard !candidates.isEmpty else { return completion(nil) }

        var results: [PlayerState] = []
        let group = DispatchGroup()
        for connector in candidates {
            group.enter()
            connector.state { state in
                if let state { results.append(state) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(results.first(where: \.isPlaying) ?? results.first)
        }
    }
}
