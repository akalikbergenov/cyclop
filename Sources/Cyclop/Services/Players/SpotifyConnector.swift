import AppKit

struct SpotifyConnector: PlayerConnector {
    let bundleID = "com.spotify.client"
    let displayName = "Spotify"
    var changeNotification: Notification.Name {
        Notification.Name("com.spotify.client.PlaybackStateChanged")
    }

    // Variable names are deliberately wordy: on macOS 26 `st` became a reserved
    // token — `set st to …` is a syntax error (-2741) even outside any tell
    // block — and a script that does not compile reads as a player that does
    // not answer. Short names are one OS update away from being stolen.
    func state(completion: @escaping (PlayerState?) -> Void) {
        runStateScript("""
        set sep to character id 1
        tell application id "com.spotify.client"
            try
                set stateText to player state as text
                set theTrack to current track
                try
                    set posMillis to (round ((player position) * 1000))
                on error
                    set posMillis to 0
                end try
                return stateText & sep & (name of theTrack) & sep & (artist of theTrack) & sep & (album of theTrack) & sep & (duration of theTrack) & sep & posMillis & sep & (artwork url of theTrack) & sep & (id of theTrack)
            on error
                return ""
            end try
        end tell
        """, completion: completion)
    }

    func playPause() { command("playpause") }
    func next() { command("next track") }

    func previous() {
        // Spotify's `previous track` restarts the current song first, matching
        // its own UI. Seeking to 0 first is what users expect from a "skip
        // back" button.
        command("set player position to 0\n    previous track")
    }

    /// Session memory for the primary artwork host. `artwork url` points at
    /// i.scdn.co; the oEmbed thumbnail lives on a different CDN, and networks
    /// exist where the first is unreachable while the second is fine. Once
    /// that is established there is no reason to pay a six-second timeout on
    /// every new track — the primary is skipped, and probed again after a
    /// while in case the network changed (a VPN toggled, a Wi-Fi switch): it
    /// serves the larger image, so it is worth taking back.
    ///
    /// The host is condemned only when the fallback *succeeds* right after it
    /// failed — that is what separates "this host is blocked" from "there is
    /// no network", which no host should be blamed for.
    @MainActor
    private enum PrimaryArtworkHost {
        static var downSince: Date?
        static let probeAfter: TimeInterval = 600
        static var worthTrying: Bool {
            guard let downSince else { return true }
            return Date().timeIntervalSince(downSince) > probeAfter
        }
    }

    /// Spotify answers `artwork url` with missing value more often than it
    /// should — always for local files, and sporadically for catalog tracks.
    /// Image *data* it refuses to hand over at all: the `artwork` property is
    /// "deprecated and will never be set". For a catalog track the cover is
    /// also reachable through the public oEmbed endpoint by the track's own
    /// id — the route taken when the URL is missing, when its host has been
    /// found dead this session, and when a fresh attempt on it fails. A local
    /// file's cover exists only inside Spotify's window; for it the honest
    /// answer is nil, which the pane shows as a placeholder rather than a
    /// skeleton that never resolves.
    func artwork(for state: PlayerState, completion: @escaping (NSImage?) -> Void) {
        guard let url = state.artworkURL, PrimaryArtworkHost.worthTrying else {
            return Self.fetchViaOEmbed(state, completion: completion)
        }
        PlayerBridge.fetchImage(url) { image in
            MainActor.assumeIsolated {
                if let image {
                    PrimaryArtworkHost.downSince = nil
                    return completion(image)
                }
                let failedAt = Date()
                Self.fetchViaOEmbed(state) { fallback in
                    MainActor.assumeIsolated {
                        if fallback != nil { PrimaryArtworkHost.downSince = failedAt }
                        completion(fallback)
                    }
                }
            }
        }
    }

    private static func fetchViaOEmbed(_ state: PlayerState, completion: @escaping (NSImage?) -> Void) {
        guard let id = state.trackID, id.hasPrefix("spotify:track:"),
              let oembed = URL(string: "https://open.spotify.com/oembed?url=\(id)") else {
            return completion(nil)
        }
        PlayerBridge.artworkSession.dataTask(with: oembed) { data, _, _ in
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumbnail = object["thumbnail_url"] as? String,
                  let url = URL(string: thumbnail)
            else { return DispatchQueue.main.async { completion(nil) } }
            PlayerBridge.fetchImage(url, completion: completion)
        }.resume()
    }

    /// A local file's cover exists only inside Spotify's window: no URL, no
    /// catalog id to look it up by, nothing any retry could change.
    func artworkIsUnobtainable(for state: PlayerState) -> Bool {
        state.artworkURL == nil && !(state.trackID?.hasPrefix("spotify:track:") ?? false)
    }
}
