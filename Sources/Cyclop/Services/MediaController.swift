import AppKit

/// Now Playing for whatever the system is playing — browser tabs included.
///
/// Primary source is `NowPlayingFeed`, which reaches MediaRemote through a
/// helper hosted by `/usr/bin/perl`. If that route ever closes, the controller
/// falls back to scripting Apple Music and Spotify directly.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var key: String
    }

    /// One of the sessions playing — or paused — at once, as the pane offers
    /// it to switch to.
    struct Source: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        let icon: NSImage?
        let isPlaying: Bool
        var id: pid_t { pid }
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var sourceName: String?
    /// Whether the player accepts skipping at all. A browser tab playing one
    /// video registers no handler for it — the command leaves and nothing
    /// happens — so the buttons go dim rather than dead, the way the system's
    /// own Now Playing widget dims them for the same session. True until told
    /// otherwise: the scripted fallback below drives Music and Spotify, and
    /// both skip fine.
    @Published private(set) var canSkip = true
    /// Every session with something to show, in a stable order. The pane
    /// offers a switch between them only when there are two or more.
    @Published private(set) var sources: [Source] = []
    /// The session on screen, by pid. Also where every command goes: what is
    /// shown is what the buttons drive.
    @Published private(set) var shownSource: pid_t?

    private let feed = NowPlayingFeed()
    private var feedAvailable = true
    private var picker = SourcePicker()
    /// The latest frame, kept so that a pick in the pane can be shown at once
    /// instead of on the helper's next line.
    private var lastFrame: NowPlayingFeed.Frame?
    /// Decoded covers, one per session. The helper sends a session's artwork
    /// only when its track changes, and a switch back to it must not wait for
    /// the next change to see a cover again.
    private var covers: [pid_t: (key: String, image: NSImage)] = [:]
    /// Covers being decoded right now, by session, with the track each is for.
    private var coming: [pid_t: String] = [:]

    private var activeApp: PlayerApp?
    private var artworkKey: String?
    private var anchor: (position: TimeInterval, at: Date)?
    /// Where we asked the player to jump, and when — see `apply`.
    private var pendingSeek: (target: TimeInterval, at: Date)?
    private var ticker: Timer?
    private var observers: [Any] = []
    /// Whether the panel is open — the ticker below runs only then.
    private var isActive = false

    // MARK: - Lifecycle

    func start() {
        feed.onUpdate = { [weak self] snapshot in self?.apply(snapshot) }
        feed.onUnavailable = { [weak self] in self?.switchToScriptingFallback() }
        feed.onAvailable = { [weak self] in self?.restoreFeed() }
        feed.start()
    }

    func stop() {
        feed.stop()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        ticker?.invalidate()
        ticker = nil
    }

    /// Panel visibility. The position ticker hangs off this: it exists to move
    /// a bar, and a bar in a collapsed panel is painted for nobody — at four
    /// wake-ups a second for as long as anything plays. The position itself is
    /// never lost, because the anchor records where it stood and when: opening
    /// computes it from there instantly, and the feed's fresh answer corrects
    /// whatever drifted a beat later.
    func setActive(_ active: Bool) {
        isActive = active
        updateTicker()
        guard active else { return }
        tick()
        if feedAvailable {
            feed.refresh()
        } else {
            refreshFromPlayers()
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        // Optimistic flip so the button feels instant; the feed corrects it.
        isPlaying.toggle()
        setAnchor(position)
        // The per-client command set has no toggle of its own (#23) — Play
        // and Pause are sent explicitly, by the state just flipped to above.
        dispatch(feed: isPlaying ? .play : .pause, script: { PlayerBridge.playPause($0) }, key: .playPause)
    }

    func next() {
        dispatch(feed: .next, script: { PlayerBridge.next($0) }, key: .next)
    }

    func previous() {
        dispatch(feed: .previous, script: { PlayerBridge.previous($0) }, key: .previous)
    }

    func seek(to seconds: TimeInterval) {
        guard duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        setAnchor(clamped)
        pendingSeek = (clamped, Date())
        if feedAvailable {
            feed.seek(to: clamped, on: shownSource ?? 0)
        } else if let activeApp {
            PlayerBridge.seek(activeApp, to: clamped)
        }
    }

    private func dispatch(
        feed command: NowPlayingFeed.Command,
        script: (PlayerApp) -> Void,
        key: PlayerBridge.MediaKey
    ) {
        if feedAvailable {
            feed.send(command, to: shownSource ?? 0)
        } else if let activeApp {
            script(activeApp)
        } else {
            PlayerBridge.postMediaKey(key.rawValue)
        }
    }

    /// Shows `pid` from now on, until something else starts playing — see
    /// `SourcePicker` for the rules that let a pick go.
    func select(_ pid: pid_t) {
        picker.pin(pid)
        if let lastFrame { show(lastFrame) }
        feed.refresh()
    }

    // MARK: - Feed

    private static func trackKey(_ snapshot: NowPlayingFeed.Snapshot) -> String {
        "\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
    }

    private func apply(_ frame: NowPlayingFeed.Frame) {
        // A session without a title has nothing to show and nothing to switch
        // to: a page that registered for media keys and never said what plays.
        let sessions = frame.sessions.filter { !$0.isEmpty }
        for session in sessions {
            if let data = session.artwork {
                decodeArtwork(data, for: Self.trackKey(session), of: session.pid)
            }
        }
        let alive = Set(sessions.map(\.pid))
        covers = covers.filter { alive.contains($0.key) }
        coming = coming.filter { alive.contains($0.key) }

        // Kept without the artwork: it has been decoded above, and a pick in
        // the pane re-shows this frame.
        var kept = frame
        kept.sessions = sessions.map { var session = $0; session.artwork = nil; return session }
        lastFrame = kept
        show(kept)
    }

    private func show(_ frame: NowPlayingFeed.Frame) {
        // Sorted by name, not taken in MediaRemote's order: that order moves
        // with activity, and icons that trade places under the pointer get
        // clicked by mistake.
        sources = frame.sessions
            .map { session in
                let app = NSRunningApplication(processIdentifier: session.pid)
                return Source(
                    pid: session.pid,
                    name: session.source ?? "",
                    icon: app?.icon,
                    isPlaying: session.isPlaying || session.rate > 0
                )
            }
            .sorted { ($0.name, $0.pid) < ($1.name, $1.pid) }
        guard let session = picker.choose(from: frame.sessions, active: frame.activePID) else {
            return clear()
        }
        apply(session)
    }

    private func apply(_ snapshot: NowPlayingFeed.Snapshot) {
        let key = Self.trackKey(snapshot)
        let switched = snapshot.pid != shownSource
        shownSource = snapshot.pid
        track = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, key: key)
        isPlaying = snapshot.isPlaying || snapshot.rate > 0
        duration = snapshot.duration
        sourceName = snapshot.source
        // Both directions travel together: no player has ever offered one
        // without the other, and two separately dimmed arrows would read as
        // a glitch rather than a limit.
        canSkip = snapshot.offers(.next) && snapshot.offers(.previous)

        let reported = reportedPosition(from: snapshot)

        if switched {
            // Another player's clock. Nothing on screen belongs to it, so
            // there is nothing to protect from it either — and a seek still
            // waiting to land was asked of the other player.
            pendingSeek = nil
            setAnchor(duration > 0 ? min(max(0, reported), duration) : max(0, reported))
        } else if let pending = pendingSeek {
            // A player needs a moment to act on a seek, and until it does it
            // keeps reporting the old position. Accepting that would yank the
            // bar back.
            let settled = abs(reported - pending.target) < 2.5
            let expired = Date().timeIntervalSince(pending.at) > 1.5
            if settled || expired {
                pendingSeek = nil
                adopt(reported)
            }
        } else {
            adopt(reported)
        }
        updateTicker()

        if artworkKey != key || switched {
            artworkKey = key
            if let cover = covers[snapshot.pid], cover.key == key {
                // Decoded earlier — the usual case on a switch.
                artwork = cover.image
            } else if !switched, coming[snapshot.pid] == key {
                // The new cover is being decoded this moment. The old one
                // stays until it lands, so a track change is one cross-fade
                // rather than a blink of skeleton between two covers.
            } else {
                // Track changed and nothing came with it; the skeleton covers
                // the gap until the system publishes the new cover.
                artwork = nil
            }
        }
    }

    /// JPEG decoding on the main thread is what makes a track change stutter,
    /// so it happens off it and the finished image is handed back.
    private func decodeArtwork(_ data: Data, for key: String, of pid: pid_t) {
        coming[pid] = key
        DispatchQueue.global(qos: .userInitiated).async {
            var image: NSImage?
            if let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage {
                image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                )
            }
            DispatchQueue.main.async { [weak self, image] in
                guard let self else { return }
                if self.coming[pid] == key { self.coming[pid] = nil }
                if let image { self.covers[pid] = (key, image) }
                guard self.shownSource == pid, self.artworkKey == key else { return }
                // A cover that would not decode leaves the skeleton, not the
                // previous track's cover held over.
                self.artwork = image
            }
        }
    }

    private func clear() {
        activeApp = nil
        track = nil
        artwork = nil
        artworkKey = nil
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        shownSource = nil
        sources = []
        canSkip = true
        updateTicker()
    }

    // MARK: - Fallback: scriptable players only

    private func switchToScriptingFallback() {
        guard feedAvailable else { return }
        feedAvailable = false
        // Nothing reports supported commands on this route, and the two apps it
        // drives both skip — so the arrows come back rather than staying dim
        // on a state no longer being refreshed. It reads one player at a time,
        // so there is nothing to switch between either.
        canSkip = true
        sources = []
        shownSource = nil
        NSLog("Cyclop: Now Playing helper unavailable, falling back to Music/Spotify scripting")

        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            observers.append(center.addObserver(
                forName: app.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.activeApp = app
                    self?.refreshFromPlayers()
                }
            })
        }
        refreshFromPlayers()
    }

    /// The helper is back after the route was declared closed. Scripting is
    /// stood down — its observers go, `activeApp` with them — and the snapshot
    /// that raised this repaints the pane from the feed as if nothing happened.
    private func restoreFeed() {
        guard !feedAvailable else { return }
        feedAvailable = true
        activeApp = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        NSLog("Cyclop: Now Playing helper is back, scripting fallback stood down")
    }

    private func refreshFromPlayers() {
        PlayerBridge.currentState { [weak self] state in
            guard let self else { return }
            guard let state else { return self.clear() }

            self.activeApp = state.app
            self.sourceName = state.app.displayName
            self.track = Track(title: state.title, artist: state.artist, album: state.album, key: state.key)
            self.isPlaying = state.isPlaying
            self.duration = state.duration
            self.adopt(state.position)
            self.updateTicker()

            guard self.artworkKey != state.key else { return }
            self.artworkKey = state.key
            self.artwork = nil
            PlayerBridge.artwork(for: state) { [weak self] image in
                guard let self, self.artworkKey == state.key else { return }
                self.artwork = image
            }
        }
    }

    // MARK: - Position

    /// What a report actually says by the time it is read.
    ///
    /// MediaRemote does not keep the elapsed time running. The field is a
    /// reading taken when the session last changed state, and the timestamp
    /// beside it says when — a tab playing for three minutes keeps reporting
    /// the second it started at, and many browsers report a plain zero. Taken
    /// literally, every refresh describes the beginning of the track, and
    /// `adopt` reads the gap as a seek made in the player and obeys it. Which
    /// is exactly what hovering did: open the panel, refresh, bar to zero.
    ///
    /// So the reading is aged by the clock that came with it. A paused session
    /// is left alone — its reading is not moving and there is nothing to add.
    private func reportedPosition(from snapshot: NowPlayingFeed.Snapshot) -> TimeInterval {
        guard snapshot.isPlaying || snapshot.rate > 0, let takenAt = snapshot.takenAt else {
            return snapshot.elapsed
        }
        let since = Date().timeIntervalSince(takenAt)
        // A stamp from the future is not a clock to add to. Trust the reading.
        guard since >= 0 else { return snapshot.elapsed }
        let rate = snapshot.rate > 0 ? snapshot.rate : 1
        let aged = snapshot.elapsed + since * rate
        return snapshot.duration > 0 ? min(aged, snapshot.duration) : aged
    }

    private func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, Date())
    }

    /// Below this a forward correction is pipeline jitter, not movement.
    private let forwardTolerance: TimeInterval = 0.75
    /// A disagreement this large is an event — a seek made in the player
    /// itself, or a track change — not a discrepancy to be smoothed over.
    private let seekThreshold: TimeInterval = 2

    /// Takes a position reported by the player, without letting the report undo
    /// what has already been shown.
    ///
    /// Every reading arrives late: the helper, the pipe and the parse sit
    /// between the player's clock and ours, so a report is normally a little
    /// *behind* the bar. Accepting it moves the bar backwards — and backwards
    /// is the one direction anybody notices, because time does not do it. So
    /// the two directions get different rules rather than one shared tolerance:
    /// backwards only for something big enough to be a real event, forwards for
    /// anything past the jitter. Left alone, the bar keeps its own count, which
    /// runs at exactly the speed the music does.
    private func adopt(_ reported: TimeInterval) {
        var value = max(0, reported)
        if duration > 0 { value = min(value, duration) }
        let delta = value - position

        if delta >= forwardTolerance || delta <= -seekThreshold {
            position = value
            anchor = (value, Date())
        } else {
            // Keep what is on screen and re-base the clock under it, so the
            // ignored difference cannot accumulate into the next comparison.
            anchor = (position, Date())
        }
    }

    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        guard isPlaying, isActive else { return }
        // Four times a second: the bar advances in sub-pixel steps, so it reads
        // as smooth without any animation smoothing the seek away with it.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let anchor, isPlaying else { return }
        let value = anchor.position + Date().timeIntervalSince(anchor.at)
        position = duration > 0 ? min(value, duration) : value
    }
}
