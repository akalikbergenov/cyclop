import AppKit
import Combine

/// Everything the user can change, in one place.
///
/// One object rather than scattered `UserDefaults` reads, because most of these
/// have to be *watched*: the panel's size is baked into a geometry struct that
/// is computed once and handed to a window, so a slider that only wrote a
/// default would change nothing until the next launch. Published here, the
/// controller can rebuild on the change and the pane can show what it did.
///
/// A singleton, and deliberately so: the panel is torn down and rebuilt
/// whenever the display arrangement changes — and now whenever its own size
/// changes, which is a settings pane sawing off the branch it sits on. Anything
/// the user would be upset to lose in that moment has to live outside the thing
/// being rebuilt.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: - Buffer

    /// How many entries the buffer keeps. The old ceilings were 40 for copies
    /// and 60 for the shelf; one list needs one number, and the larger of the
    /// two is the one nobody notices.
    @Published var bufferLimit: Int {
        didSet { defaults.set(bufferLimit, forKey: "buffer.limit") }
    }

    static let bufferLimitRange = 10...300

    /// Whether copied *text* survives a relaunch.
    ///
    /// Off by default, and that is a deliberate answer rather than a shrug.
    /// Files in the buffer are references to things already on disk, and
    /// keeping a list of them costs the user nothing they had not already
    /// accepted. Copied text is different: it is the passwords, the addresses
    /// and the one-time codes that passed through the clipboard, and writing
    /// that to disk is a promise this app has not been making. Anyone who wants
    /// the convenience can have it — from here, knowingly.
    @Published var keepTextBetweenLaunches: Bool {
        didSet { defaults.set(keepTextBetweenLaunches, forKey: "buffer.keepText") }
    }

    /// Whether a copied image is written to disk and kept. Old key, kept as it
    /// was so nobody's choice is reset by the rename.
    @Published var saveImages: Bool {
        didSet { defaults.set(saveImages, forKey: "saveClipboardImages") }
    }

    // MARK: - Shortcuts

    @Published var bufferHotKey: HotKeyCombo? {
        didSet { store(bufferHotKey, as: "hotkey.buffer") }
    }

    /// Takes a screenshot. ⌘⇧A by default — ⌘⇧3/4/5 belong to macOS's own
    /// screenshots and taking one of those away would be rude, and ⌘⇧A is what
    /// the tools people are coming from use.
    @Published var shotHotKey: HotKeyCombo? {
        didSet { store(shotHotKey, as: "hotkey.shot") }
    }

    /// Which language the text recogniser should expect. Empty means "let
    /// Vision decide", which follows the user's own preferred languages.
    @Published var ocrLanguage: String {
        didSet { defaults.set(ocrLanguage, forKey: "ocr.language") }
    }

    /// Opens and closes the panel itself. Off by default: the panel already
    /// opens by hovering, and a shortcut nobody asked for is one more
    /// combination taken away from every other app on the machine.
    @Published var panelHotKey: HotKeyCombo? {
        didSet { store(panelHotKey, as: "hotkey.panel") }
    }

    /// Whether the panel unfolds when the pointer reaches the notch.
    ///
    /// On by default, because that is what the app is: a thing that answers a
    /// glance. Off for people whose work takes them to the top of the screen
    /// all day — a panel that opens over the menu they were reaching for is
    /// worse than one that needs a click, and the shortcut is there too.
    @Published var opensOnHover: Bool {
        didSet { defaults.set(opensOnHover, forKey: "panel.opensOnHover") }
    }

    /// Whether taking a screenshot makes the shutter sound.
    ///
    /// On, because the sound is the confirmation: the editor vanishes at the
    /// same moment, and without either a noise or a flash there is nothing to
    /// tell a shot that was taken from one that was cancelled.
    @Published var shotSound: Bool {
        didSet { defaults.set(shotSound, forKey: "shot.sound") }
    }

    // MARK: - Size

    /// The expanded panel's body. Bounds are what the layout survives: the
    /// rails and panes stop making sense much below this, and much above it the
    /// panel stops being a notch and becomes a window.
    @Published var panelWidth: Double {
        didSet { defaults.set(panelWidth, forKey: "panel.width") }
    }

    @Published var panelHeight: Double {
        didSet { defaults.set(panelHeight, forKey: "panel.height") }
    }

    /// Width of the pretend notch on a Mac that has no real one. Ignored on a
    /// Mac that does — the cutout is a physical fact and the panel measures it.
    @Published var notchWidth: Double {
        didSet { defaults.set(notchWidth, forKey: "notch.width") }
    }

    static let panelWidthRange = 420.0...980.0
    static let panelHeightRange = 170.0...340.0
    static let notchWidthRange = 120.0...360.0

    static let defaultPanelWidth = 620.0
    static let defaultPanelHeight = 208.0
    static let defaultNotchWidth = 180.0

    /// Raised when a change requires the panel to be built again — its size is
    /// baked into the window's frame and into every hover rect derived from it.
    let geometryDidChange = PassthroughSubject<Void, Never>()

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // A local function rather than a closure: this runs before `self` is
        // fully initialised, and a closure would have to capture it.
        func stored(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: key) != nil else { return fallback }
            return min(max(defaults.double(forKey: key), range.lowerBound), range.upperBound)
        }

        let defaults = UserDefaults.standard
        bufferLimit = defaults.object(forKey: "buffer.limit") == nil
            ? 60
            : min(max(defaults.integer(forKey: "buffer.limit"), 10), 300)
        keepTextBetweenLaunches = defaults.bool(forKey: "buffer.keepText")
        opensOnHover = defaults.object(forKey: "panel.opensOnHover") == nil
            ? true
            : defaults.bool(forKey: "panel.opensOnHover")
        // On by default: the folder of saved screenshots is the reason this
        // setting exists, not a thing to opt into.
        saveImages = defaults.object(forKey: "saveClipboardImages") == nil
            ? true
            : defaults.bool(forKey: "saveClipboardImages")
        panelWidth = stored("panel.width", Self.defaultPanelWidth, Self.panelWidthRange)
        panelHeight = stored("panel.height", Self.defaultPanelHeight, Self.panelHeightRange)
        notchWidth = stored("notch.width", Self.defaultNotchWidth, Self.notchWidthRange)

        bufferHotKey = Self.read("hotkey.buffer") ?? HotKeyCombo.defaultBuffer
        panelHotKey = Self.read("hotkey.panel")
        shotHotKey = Self.read("hotkey.shot") ?? HotKeyCombo.defaultShot
        ocrLanguage = defaults.string(forKey: "ocr.language") ?? ""
        shotSound = defaults.object(forKey: "shot.sound") == nil
            ? true
            : defaults.bool(forKey: "shot.sound")

        // Coalesced, because the size controls are held down: a stepper repeats
        // while pressed and a rebuild per repeat would tear the panel down and
        // build it again a dozen times on the way to the wanted number, each
        // one throwing away the pane the user is pressing the button in.
        Publishers.Merge3(
            $panelWidth.map { _ in () },
            $panelHeight.map { _ in () },
            $notchWidth.map { _ in () }
        )
        .dropFirst(3)
        .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
        .sink { [weak self] in self?.geometryDidChange.send() }
        .store(in: &cancellables)
    }

    /// Back to how the app ships. Only the sizes and the shortcuts: what is in
    /// the buffer is the user's, and a "reset" that quietly emptied it would be
    /// the last button anyone here presses by accident.
    func resetLayoutAndShortcuts() {
        panelWidth = Self.defaultPanelWidth
        panelHeight = Self.defaultPanelHeight
        notchWidth = Self.defaultNotchWidth
        bufferHotKey = HotKeyCombo.defaultBuffer
        panelHotKey = nil
        shotHotKey = HotKeyCombo.defaultShot
        geometryDidChange.send()
    }

    // MARK: - Storing shortcuts

    private func store(_ combo: HotKeyCombo?, as key: String) {
        guard let combo, let data = try? JSONEncoder().encode(combo) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func read(_ key: String) -> HotKeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }
}

/// A recorded shortcut: which physical key, which modifiers, and what to call
/// it on screen.
///
/// The label is recorded rather than derived. Deriving it means asking the
/// current keyboard layout what a key code prints, and the answer changes with
/// the layout — the same physical key is V on one and М on another, so a label
/// computed at draw time renames a shortcut the user never touched. What was
/// pressed is what the row says.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask — what `RegisterEventHotKey` takes.
    var modifiers: UInt32
    var label: String

    static let defaultBuffer = HotKeyCombo(
        keyCode: 9,
        modifiers: HotKey.Modifiers([.command, .option]).rawValue,
        label: "⌘⌥V"
    )

    static let defaultShot = HotKeyCombo(
        keyCode: 0,
        modifiers: HotKey.Modifiers([.command, .shift]).rawValue,
        label: "⌘⇧A"
    )

    /// Whether this is a combination the window server will actually hand over,
    /// and one the user can get back out of. A bare key would swallow that key
    /// everywhere on the machine — including in the field they are typing in.
    var isUsable: Bool { modifiers != 0 }
}
