import AppKit

/// The script, and where reading it has got to.
///
/// The notch is the one place on the screen where a teleprompter belongs: it
/// sits directly under the camera, so the eyes stay on the lens instead of
/// travelling to a window somewhere below it. Every other tab is here because
/// there is room; this one is here because of where the room is.
@MainActor
final class TeleprompterStore: ObservableObject {
    /// The text being read. Kept between launches — a script is written once
    /// and read several times, often over several takes.
    @Published var script: String = "" {
        didSet {
            guard script != oldValue else { return }
            // Rewriting the script mid-take would leave the scroll pointing at
            // a line that no longer exists.
            offset = 0
            scheduleSave()
        }
    }

    /// Points per second the text creeps upward at 1×. Slow: a comfortable
    /// reading pace is far slower than anyone guesses before trying it, and
    /// the speed control multiplies this.
    static let baseRate: CGFloat = 22

    /// Multiplier on `baseRate`. Adjustable mid-take, because the pace that
    /// felt right while setting up never survives the first paragraph.
    @Published var speed: Double = 1.0 {
        didSet {
            guard speed != oldValue else { return }
            ConfigStore.shared.teleprompterSpeed = speed
        }
    }

    /// Point size of the script. What makes a teleprompter legible is type
    /// large enough to read at a glance, without focusing — the glance is all
    /// the attention available while talking to a camera.
    @Published var fontSize: Double = 30 {
        didSet {
            guard fontSize != oldValue else { return }
            ConfigStore.shared.teleprompterFontSize = fontSize
        }
    }

    /// How far the text has scrolled, in points. Not persisted: a new session
    /// starts at the top, which is where a take starts.
    @Published var offset: CGFloat = 0
    @Published private(set) var isRunning = false

    /// Height of the text as laid out, set by the pane once it knows. Scrolling
    /// stops here rather than running the script off into empty space.
    var contentHeight: CGFloat = 0
    /// Height of the window the text scrolls through, also from the pane.
    var viewportHeight: CGFloat = 0

    private static let file = Support.file("teleprompter.txt")

    private var timer: Timer?
    private let saves = DebouncedWrite()

    init() {
        script = (try? String(contentsOf: Self.file, encoding: .utf8)) ?? ""
        // Reading the file above went through `script`'s observer and armed a
        // save of what was just loaded. Harmless, but worth not doing.
        saves.cancel()
        // Persisted in `config.json` (#67) since before this store existed —
        // the clamps guard a value hand-edited in the file past what the
        // slider itself allows.
        speed = min(max(ConfigStore.shared.teleprompterSpeed, 0.3), 3.0)
        fontSize = min(max(ConfigStore.shared.teleprompterFontSize, 18), 64)
    }

    // MARK: - Running

    /// The furthest the text may scroll: the last line stops in the middle of
    /// the window rather than at the top edge, so it is still being read from
    /// the same place as every line before it.
    var maxOffset: CGFloat {
        max(0, contentHeight - viewportHeight / 2)
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !script.isEmpty, !isRunning else { return }
        if offset >= maxOffset { offset = 0 }
        isRunning = true
        // 60 Hz rather than a per-line jump: text that steps line by line is
        // read in lurches, and the eye loses the line it was on at every step.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func rewind() {
        pause()
        offset = 0
    }

    /// Stops the clock and leaves the position alone. For the panel closing or
    /// the tab changing, where the only thing that has to happen immediately is
    /// that the text stops moving — where it stopped is decided on the way back
    /// in, by the pane, which puts it at the top.
    func suspend() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func tick() {
        guard isRunning else { return }
        offset = min(maxOffset, offset + Self.baseRate * CGFloat(speed) / 60.0)
        if offset >= maxOffset { pause() }
    }

    // MARK: - Storage

    /// Plain text, not JSON. The script is written elsewhere and pasted here,
    /// and a file anyone can open in any editor is worth more than a format
    /// only this app reads.
    private func scheduleSave() {
        saves.schedule { [weak self] in self?.persist() }
    }

    func flush() { saves.flush() }

    private func persist() {
        do {
            try script.write(to: Self.file, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Cyclop: cannot write teleprompter.txt: \(error.localizedDescription)")
        }
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? "".write(to: file, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
