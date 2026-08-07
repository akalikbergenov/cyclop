import AppKit

/// Plumbing shared by every `PlayerConnector`: the AppleScript runner, the
/// artwork network session, and the system media keys. Player-specific
/// knowledge lives in the connectors themselves — see `Services/Players/`.
enum PlayerBridge {
    private static let queue = DispatchQueue(label: "com.cyclop.applescript", qos: .utility)

    // MARK: - AppleScript

    /// Compiled scripts, keyed by source. The state script runs every second
    /// while the panel is open, and compiling it each time costs more than
    /// running it — enough to push the round trip past the poll interval.
    /// Touched only from `queue`, which also makes the non-thread-safe
    /// `NSAppleScript` safe to reuse.
    private static var compiled: [String: NSAppleScript] = [:]

    /// Shared AppleScript runner: one serial queue for every script the app sends.
    static func runScript(_ source: String, completion: @escaping (NSAppleEventDescriptor?) -> Void) {
        queue.async {
            let script: NSAppleScript
            if let cached = compiled[source] {
                script = cached
            } else if let fresh = NSAppleScript(source: source) {
                compiled[source] = fresh
                script = fresh
            } else {
                return DispatchQueue.main.async { completion(nil) }
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error, let code = error[NSAppleScript.errorNumber] as? Int, code != 0 {
                NSLog("Cyclop: AppleScript error \(code): \(error[NSAppleScript.errorMessage] ?? "")")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Artwork network

    /// Session for cover fetches. The shared session waits a minute before
    /// giving up, and on a weak network — or one where Spotify's CDN stalls at
    /// the TLS handshake, which happens — that minute is spent shimmering a
    /// skeleton at the user. Covers are small: if one has not arrived in
    /// seconds, it is not arriving, and the retry loop upstream should hear
    /// about it while the track is still playing.
    static let artworkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    /// The only thing the app ever fetches over the network. Addresses come
    /// out of another app's scripting dictionary, so the scheme is checked:
    /// https answers for itself through TLS, while file:// or some private
    /// scheme answers to nobody.
    static func fetchImage(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        guard url.scheme?.lowercased() == "https" else { return completion(nil) }
        artworkSession.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    // MARK: - Media keys

    /// System-wide media key, used when no addressable player owns the session.
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
}
