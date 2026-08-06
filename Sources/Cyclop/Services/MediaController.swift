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

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    /// True once every route to a cover has answered no — the pane switches
    /// from skeleton to placeholder, because a shimmer that never resolves
    /// reads as the app failing rather than the track having no art.
    @Published private(set) var artworkUnavailable = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var sourceName: String?

    private let feed = NowPlayingFeed()
    private var feedAvailable = true

    /// The connector for the app owning the session, when we have one.
    /// Everything that can go through a connector does, because for those
    /// players the system's own record is neither current nor commandable —
    /// see `apply`.
    private var activeConnector: (any PlayerConnector)?
    private var artworkKey: String?
    /// Failed attempts for the current track, spacing the next try further out
    /// each time. The poll arrives every second; without the spacing a dead
    /// network would be asked for the same cover sixty times a minute, and
    /// with a permanent give-up it would never be asked again even after the
    /// network came back mid-track.
    private var artworkRetries = 0
    private var artworkRetryKey: String?
    private var artworkRetryAt = Date.distantPast
    /// Covers fetched this session, keyed by track. On a weak network a cover
    /// is an achievement — walking prev/next must not throw it away and start
    /// the shimmer over.
    private var artworkCache: [String: NSImage] = [:]
    private var artworkCacheOrder: [String] = []
    /// The cover the system last published, kept aside by title. Local bytes,
    /// already paid for: Spotify's own scripting interface refuses to hand
    /// over image data (`artwork` is "deprecated and will never be set"), so
    /// when the daemon's record does carry the picture it is the only way to
    /// put a cover up without touching the network at all.
    private var helperArtwork: (title: String, image: NSImage)?
    private var anchor: (position: TimeInterval, at: Date)?
    /// Speed the player reported, so a podcast at 1.5× does not walk away from
    /// a bar that always counted at 1×.
    private var playbackRate: Double = 1
    /// Where we asked the player to jump, and when — see `adoptReported`.
    private var pendingSeek: (target: TimeInterval, at: Date)?
    /// The previous reading, kept to tell whether the player's clock is
    /// actually moving. Cleared after anything discontinuous — a track change,
    /// our own seek — so the first comparison afterwards starts fresh.
    private var lastReading: (position: TimeInterval, at: Date)?
    /// True while the player claims to be playing but its reported position is
    /// not moving: buffering, in practice. The player's "playing" means "I
    /// intend to play", and on a weak connection intent can run ahead of audio
    /// by many seconds. A bar that keeps counting through that is lying, and
    /// worse, it gets yanked back on every correction — so while the player's
    /// clock stands still, ours does too.
    private var isStalled = false
    private var ticker: Timer?
    /// Ordering for script answers: a response older than one already applied
    /// is discarded. *Only* that — discarding merely-overtaken responses is a
    /// trap, because queries go out once a second and a script that takes
    /// longer than that to answer means every response arrives overtaken:
    /// each one thrown away, the panel frozen on whatever it showed first.
    private var queryCounter = 0
    private var appliedQuery = 0
    private var poller: Timer?
    private var observers: [Any] = []
    /// Whether the panel is open — the ticker below runs only then.
    private var isActive = false

    // MARK: - Lifecycle

    func start() {
        feed.onUpdate = { [weak self] snapshot in self?.apply(snapshot) }
        feed.onUnavailable = { [weak self] in self?.switchToScriptingFallback() }
        feed.start()
    }

    func stop() {
        feed.stop()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        ticker?.invalidate()
        ticker = nil
        poller?.invalidate()
        poller = nil
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
        updatePoller()
        guard active else { return }
        tick()
        refresh()
    }

    /// Asks whatever source is in use where things stand.
    private func refresh() {
        if feedAvailable {
            feed.refresh()
        } else {
            refreshFromPlayers()
        }
    }

    /// The system is supposed to announce Now Playing changes, and the helper
    /// forwards them when it gets them — but on macOS 26.5.2 it does not get
    /// them: across repeated half-minute windows containing real track changes
    /// and play/pause, not one notification arrived. Left waiting, the panel
    /// shows whatever was true when it opened. So while it is open we ask,
    /// twice a second being pointless for a record the player updates rarely
    /// and once a second being enough to feel live.
    private func updatePoller() {
        poller?.invalidate()
        poller = nil
        guard isActive else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    /// A command needs a beat to reach the player and come back as fact. The
    /// poller would catch it within the second anyway; this only shortens the
    /// window in which the optimistic guess stands unverified.
    private func verifySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        // Optimistic flip so the button feels instant; the refresh corrects it.
        isPlaying.toggle()
        setAnchor(position)
        dispatch(feed: .togglePlayPause, script: { $0.playPause() }, key: .playPause)
    }

    func next() {
        dispatch(feed: .next, script: { $0.next() }, key: .next)
    }

    func previous() {
        dispatch(feed: .previous, script: { $0.previous() }, key: .previous)
    }

    func seek(to seconds: TimeInterval) {
        guard duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        setAnchor(clamped)
        pendingSeek = (clamped, Date())
        // The jump is discontinuous by design; comparing readings across it
        // would read as either movement or a stall, and it is neither.
        lastReading = nil
        isStalled = false
        // The connector first for the same reason as every other command
        // below, and with more at stake: the system's seek is the one call
        // that can leave things worse than it found them.
        if let activeConnector {
            activeConnector.seek(to: clamped)
        } else if feedAvailable {
            feed.seek(to: clamped)
        }
        verifySoon()
    }

    /// Order matters, and it is the reverse of what the layering suggests.
    ///
    /// The helper is the better *source* — it sees browser tabs and everything
    /// else the system knows about, which no connector can reach. It is not the
    /// better *remote*. On macOS 26.5.2 `MRMediaRemoteSendCommand` reports
    /// success for every command and delivers none of them: play/pause leaves
    /// the player playing, seek leaves the playhead where it was. The
    /// connectors answer exactly, so when the session belongs to one of them
    /// the command goes there and the helper is left to do what it is good at.
    /// Anything else still goes through the helper, and a media key remains
    /// the last resort for a session nothing else can address.
    private func dispatch(
        feed command: NowPlayingFeed.Command,
        script: (any PlayerConnector) -> Void,
        key: PlayerBridge.MediaKey
    ) {
        if let activeConnector {
            script(activeConnector)
        } else if feedAvailable {
            feed.send(command)
        } else {
            PlayerBridge.postMediaKey(key.rawValue)
        }
        verifySoon()
    }

    // MARK: - Feed

    /// Routes the helper's record to whoever can be trusted with it.
    ///
    /// The helper is the only source that sees every session — browser tabs,
    /// games, anything the system knows about — and for those it is also the
    /// only source there is. For Apple Music and Spotify it is merely the one
    /// that answers first. Its record for them lags: mid-test it was still
    /// describing a song that had already finished, three minutes of playback
    /// after the fact. So when it names one of those two as the owner, that is
    /// the useful part of the answer, and the player itself is asked for the
    /// rest.
    private func apply(_ snapshot: NowPlayingFeed.Snapshot) {
        // An empty record is not evidence of silence. On macOS 26.5.2 the
        // daemon can miss a session entirely — Spotify freshly launched and
        // audibly playing while the record stayed blank — so before showing
        // "nothing is playing" the scriptable players get asked directly, and
        // only their silence clears the pane.
        guard !snapshot.isEmpty else { return refreshFromPlayers() }

        // Whatever route the rest of the record takes, cover bytes are kept:
        // the script path may want them the moment its own sources come back
        // empty-handed.
        if let data = snapshot.artwork { stashHelperArtwork(data, title: snapshot.title) }

        guard let connector = PlayerConnectors.match(bundleID: snapshot.bundleID) else {
            activeConnector = nil
            return applyReported(snapshot)
        }

        activeConnector = connector
        queryCounter += 1
        let query = queryCounter
        connector.state { [weak self] state in
            guard let self, query > self.appliedQuery else { return }
            self.appliedQuery = query
            guard let state else {
                // The player will not answer — automation refused, most likely.
                // Fall back to the helper for the reading *and* for the
                // transport, rather than keep aiming commands at a route that
                // just failed. The next poll tries the player again.
                self.activeConnector = nil
                return self.applyReported(snapshot)
            }
            self.applyScripted(state)
        }
    }

    /// Position bookkeeping that must not survive a change of track: a seek
    /// aimed at the old track would hold the bar hostage against readings from
    /// the new one, and a movement comparison across the boundary would call
    /// the jump a stall or a sprint when it is neither.
    private func noteTrackChanged() {
        pendingSeek = nil
        lastReading = nil
        isStalled = false
    }

    /// Everything from a player that answered for itself.
    private func applyScripted(_ state: PlayerState) {
        if track?.key != state.key { noteTrackChanged() }
        sourceName = state.connector.displayName
        track = Track(title: state.title, artist: state.artist, album: state.album, key: state.key)
        isPlaying = state.isPlaying
        if state.duration > 0 { duration = state.duration }
        playbackRate = 1
        adoptReported(state.position)
        updateTicker()

        loadArtwork(for: state)
    }

    /// Keeps the cover in step with the track over a network that cannot be
    /// counted on. Runs on every poll, so all it may do per call is one step:
    /// serve the cache, start one fetch, or decline until the backoff passes.
    private func loadArtwork(for state: PlayerState) {
        // A cover the system already delivered for this same track goes
        // straight into the cache — free, local, and not subject to the
        // network being in a mood.
        if artworkCache[state.key] == nil,
           let stashed = helperArtwork, stashed.title == state.title {
            artworkCache[state.key] = stashed.image
            artworkCacheOrder.append(state.key)
        }

        if let cached = artworkCache[state.key] {
            artworkKey = state.key
            if artwork !== cached { artwork = cached }
            artworkUnavailable = false
            return
        }

        // Track changed: the old cover comes down right away, whatever state
        // the previous fetch was in. Its late result is dropped by the
        // retry-key guard in the completion below.
        if artworkRetryKey != state.key {
            artworkRetryKey = state.key
            artworkRetries = 0
            artworkRetryAt = .distantPast
            artworkKey = nil
            artwork = nil
            artworkUnavailable = false
        }

        // Already in flight, or concluded hopeless, for this same track.
        guard artworkKey != state.key else { return }

        // Some tracks have no cover any route could reach — the connector
        // knows which (Spotify local files, in practice). Nothing to retry.
        if state.connector.artworkIsUnobtainable(for: state) {
            artworkKey = state.key
            artworkUnavailable = true
            return
        }

        guard Date() >= artworkRetryAt else { return }
        artworkKey = state.key
        state.connector.artwork(for: state) { [weak self] image in
            guard let self, self.artworkRetryKey == state.key else { return }
            if let image {
                self.artworkCache[state.key] = image
                self.artworkCacheOrder.append(state.key)
                if self.artworkCacheOrder.count > 12 {
                    self.artworkCache.removeValue(forKey: self.artworkCacheOrder.removeFirst())
                }
                self.artworkKey = state.key
                self.artwork = image
                self.artworkUnavailable = false
            } else {
                // Not now — maybe later. The placeholder goes up immediately:
                // tying the shimmer's lifetime to a slow network makes the app
                // read as hung, while a placeholder that later resolves into
                // the cover reads as the network being the network.
                self.artworkRetries += 1
                self.artworkUnavailable = true
                self.artworkKey = nil
                self.artworkRetryAt = Date().addingTimeInterval(min(60, Double(self.artworkRetries) * 5))
            }
        }
    }

    /// Everything from the helper, for a session nothing else can reach.
    private func applyReported(_ snapshot: NowPlayingFeed.Snapshot) {
        let key = "\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        if track?.key != key { noteTrackChanged() }
        track = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, key: key)
        isPlaying = snapshot.isPlaying || snapshot.rate > 0
        duration = snapshot.duration
        sourceName = snapshot.source
        playbackRate = snapshot.rate > 0 ? snapshot.rate : 1
        // `livePosition`, never `elapsed`: the reading on its own is frozen at
        // the moment the player last published it, and taking it at face value
        // is what pinned the bar to 0:00 on a track minutes in.
        adoptReported(snapshot.livePosition)
        updateTicker()

        if let data = snapshot.artwork {
            artworkKey = key
            artworkUnavailable = false
            decodeArtwork(data, for: key)
        } else if artworkKey != key {
            // Track changed and the payload carried no artwork; the skeleton
            // covers the gap until the system publishes the new cover.
            artworkKey = key
            artwork = nil
            artworkUnavailable = false
        } else if artwork == nil {
            // Second look at the same track and still nothing: the system has
            // had its chance, stop shimmering. A later publish that does carry
            // the cover still lands through the branch above.
            artworkUnavailable = true
        }
    }

    /// Decodes off-main and keeps the result by title, for `loadArtwork`.
    private func stashHelperArtwork(_ data: Data, title: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else { return }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            )
            DispatchQueue.main.async { self?.helperArtwork = (title, image) }
        }
    }

    /// JPEG decoding on the main thread is what makes a track change stutter,
    /// so it happens off it and the finished image is handed back.
    private func decodeArtwork(_ data: Data, for key: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else { return }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.artworkKey == key else { return }
                self.artwork = image
            }
        }
    }

    /// Gate in front of `adopt` for a position a source reported.
    ///
    /// A player needs a moment to act on a seek, and until it does it keeps
    /// reporting the old position. Accepting that would yank the bar back to
    /// where the drag started. The wait is generous because the cost of the two
    /// mistakes is not symmetric: holding the bar a moment too long is
    /// invisible, while dropping it back and returning is the rubber-band the
    /// scrubber is judged on.
    private func adoptReported(_ reported: TimeInterval) {
        let now = Date()

        // Is the player's own clock moving? Two readings a beat apart answer
        // that; the stall flag freezes our ticker while the answer is no.
        var moving = false
        if let last = lastReading {
            let dt = now.timeIntervalSince(last.at)
            if dt >= 0.8 {
                moving = abs(reported - last.position) >= 0.2 * dt
                isStalled = isPlaying && !moving
                lastReading = (reported, now)
            } else {
                moving = abs(reported - last.position) >= 0.1
            }
        } else {
            lastReading = (reported, now)
        }

        if let pending = pendingSeek {
            let age = now.timeIntervalSince(pending.at)
            let settled = abs(reported - pending.target) < 2.5
            // A frozen reading is not the player refusing the seek — it is the
            // player buffering its way toward it, which on a weak connection
            // takes as long as it takes. Only a reading moving somewhere else
            // means the seek lost; a stuck one just extends the hold, up to a
            // cap that stops a dead player from pinning the bar forever.
            let overridden = age > 3 && moving && abs(reported - pending.target) >= 2.5
            let gaveUp = age > 15
            guard settled || overridden || gaveUp else { return }
            pendingSeek = nil
        }
        adopt(reported)
    }

    private func clear() {
        noteTrackChanged()
        activeConnector = nil
        track = nil
        artwork = nil
        artworkKey = nil
        artworkUnavailable = false
        artworkRetries = 0
        artworkRetryKey = nil
        artworkRetryAt = .distantPast
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        updateTicker()
    }

    // MARK: - Fallback: scriptable players only

    private func switchToScriptingFallback() {
        guard feedAvailable else { return }
        feedAvailable = false
        NSLog("Cyclop: Now Playing helper unavailable, falling back to player connectors")

        let center = DistributedNotificationCenter.default()
        for connector in PlayerConnectors.all {
            observers.append(center.addObserver(
                forName: connector.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.activeConnector = connector
                    self?.refreshFromPlayers()
                }
            })
        }
        refreshFromPlayers()
    }

    private func refreshFromPlayers() {
        PlayerConnectors.currentState { [weak self] state in
            guard let self else { return }
            guard let state else { return self.clear() }
            self.activeConnector = state.connector
            self.applyScripted(state)
        }
    }

    // MARK: - Position

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
        // Idempotent: a reading now arrives every second, and tearing the timer
        // down and building it back up each time would reset its phase on every
        // one of them, leaving the bar to advance in uneven steps.
        let shouldRun = isPlaying && isActive
        guard shouldRun != (ticker != nil) else { return }
        ticker?.invalidate()
        ticker = nil
        guard shouldRun else { return }
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
        guard let anchor, isPlaying, !isStalled else { return }
        // Scaled by the rate: a podcast at 1.5× moves half again as far per
        // second, and a bar that always counted at 1× would fall steadily
        // behind and be dragged forward by every reading that corrected it.
        let value = anchor.position + Date().timeIntervalSince(anchor.at) * playbackRate
        position = duration > 0 ? min(value, duration) : value
    }
}
