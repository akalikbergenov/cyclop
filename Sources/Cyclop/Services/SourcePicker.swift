import Foundation

/// Which of several Now Playing sessions the music pane shows.
///
/// macOS names one session "now playing" and does not always move the name
/// when it should: a YouTube tab paused a while ago can keep it while Yandex
/// Music plays, and a pane that only followed the system showed the paused
/// video with no way over to the music. So the system's choice is a tiebreak
/// here, not the answer. In order:
///
/// 1. A session picked by hand, until it goes away or another one starts
///    playing.
/// 2. Of the sessions playing, the one that started last. Pressing play is the
///    clearest thing anybody says about what they are listening to, wherever
///    it is pressed — in the pane or in the player — and the latest one said
///    wins. It is also what lets a start take over from a pick.
/// 3. Of the sessions playing, the system's choice, then any.
/// 4. With nothing playing, whatever was on screen: pausing the music is not
///    a request to be shown a video paused an hour ago.
/// 5. The system's choice, then whatever is left.
///
/// Pure on purpose: the rules are the part that can be wrong without a single
/// view being involved, so they are kept where a test can reach them.
struct SourcePicker {
    /// The session chosen by hand, by pid.
    private(set) var pinned: pid_t?
    /// Who was playing on the previous frame — what tells a session that has
    /// just started from one that has been playing all along.
    private var playing: Set<pid_t> = []
    /// The session seen starting most recently.
    private var lead: pid_t?
    /// What the previous frame showed.
    private var shown: pid_t?

    mutating func pin(_ pid: pid_t) {
        pinned = pid
    }

    /// The session to show out of `sessions`, given the pid macOS considers
    /// active. Nil only when there are no sessions at all.
    mutating func choose(
        from sessions: [NowPlayingFeed.Snapshot],
        active: pid_t
    ) -> NowPlayingFeed.Snapshot? {
        let audible = sessions.filter { $0.isPlaying || $0.rate > 0 }
        let started = audible.filter { !playing.contains($0.pid) }
        playing = Set(audible.map(\.pid))
        // Several at once happens on the first frame, when everything playing
        // is new to us: the system's word settles it.
        if let first = started.first(where: { $0.pid == active }) ?? started.first {
            lead = first.pid
        }

        if let pinned {
            let gone = !sessions.contains { $0.pid == pinned }
            let overtaken = started.contains { $0.pid != pinned }
            if gone || overtaken { self.pinned = nil }
        }

        func session(_ pid: pid_t?) -> NowPlayingFeed.Snapshot? {
            pid.flatMap { pid in sessions.first { $0.pid == pid } }
        }
        let chosen = session(pinned)
            ?? audible.first { $0.pid == lead }
            ?? audible.first { $0.pid == active }
            ?? audible.first
            ?? session(shown)
            ?? session(active)
            ?? sessions.first
        shown = chosen?.pid
        return chosen
    }
}
