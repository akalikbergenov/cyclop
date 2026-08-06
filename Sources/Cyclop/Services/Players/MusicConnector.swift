import AppKit

struct MusicConnector: PlayerConnector {
    let bundleID = "com.apple.Music"
    let displayName = "Apple Music"
    var changeNotification: Notification.Name {
        Notification.Name("com.apple.Music.playerInfo")
    }

    // See SpotifyConnector for why the variable names are wordy.
    func state(completion: @escaping (PlayerState?) -> Void) {
        runStateScript("""
        set sep to character id 1
        tell application id "com.apple.Music"
            try
                set stateText to player state as text
                set theTrack to current track
                try
                    set posMillis to (round ((player position) * 1000))
                on error
                    set posMillis to 0
                end try
                return stateText & sep & (name of theTrack) & sep & (artist of theTrack) & sep & (album of theTrack) & sep & (round ((duration of theTrack) * 1000)) & sep & posMillis & sep & "" & sep & ""
            on error
                return ""
            end try
        end tell
        """, completion: completion)
    }

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("back track") }

    /// Music, unlike Spotify, hands the actual bytes over — no network at all.
    func artwork(for state: PlayerState, completion: @escaping (NSImage?) -> Void) {
        PlayerBridge.runScript("""
        tell application id "com.apple.Music"
            if (count of artworks of current track) is 0 then return missing value
            return raw data of artwork 1 of current track
        end tell
        """) { descriptor in
            guard let data = descriptor?.data, !data.isEmpty else { return completion(nil) }
            completion(NSImage(data: data))
        }
    }
}
