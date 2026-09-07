import AppKit

/// Everything about Cyclop that makes sense on somebody else's Mac, in one
/// file next to `snippets.json` and `notes.json` (#67).
///
/// Before this, the same handful of settings each kept their own place and
/// their own copy of "and what if the key isn't there yet": `showOnAllDisplays`
/// in `NotchGeometry`, `saveClipboardImages` in `NotchViewModel`, the privacy
/// sections in `PrivacyMode`, the teleprompter's speed and font size in
/// `TeleprompterStore`, and, freshest, the tab switches from #80. Harmless at
/// four; every new setting was the fifth spelling of the same question.
///
/// **What comes here.** What has meaning on another Mac. Shelf paths (content,
/// not configuration) and calendar overrides (tied to calendar identifiers on
/// this particular Mac) stay in `UserDefaults` — see #67 for the rule.
///
/// **Migration.** No file yet → built once from the old `UserDefaults` keys
/// and written. The old keys are then left alone: rolling back to a build
/// before this one loses a few switches rather than this app carrying two
/// sources of truth for one release (decided in #67).
@MainActor
final class ConfigStore: ObservableObject {
    private struct Teleprompter: Codable, Equatable {
        var speed: Double = 1
        var fontSize: Double = 30
    }

    private struct File: Codable, Equatable {
        var showOnAllDisplays = true
        var saveClipboardImages = true
        var privacy: [String] = []
        var teleprompter = Teleprompter()
        var hiddenTabs: [String] = []
    }

    static let shared = ConfigStore()

    /// `~/Library/Application Support/Cyclop/config.json`.
    static let file = Support.file("config.json")

    /// True when the file exists but cannot be parsed — same meaning and the
    /// same consequence as `SnippetStore.fileBroken` (#7): reading stays
    /// honest, and writing stops rather than paving over a hand edit gone
    /// wrong.
    @Published private(set) var fileBroken = false

    private var value: File

    private init() {
        if let data = try? Data(contentsOf: Self.file) {
            do {
                value = try JSONDecoder().decode(File.self, from: data)
            } catch {
                value = File()
                fileBroken = true
                NSLog("Cyclop: config.json is not readable: \(error.localizedDescription)")
            }
        } else {
            // Nothing on disk yet, so nothing to protect — assembled from
            // whatever the old keys already say and written straight away.
            value = Self.migrated()
            write(value)
        }
    }

    // MARK: - Settings

    /// Persisted switch for every display past the first. Defaults to on: the
    /// panel is meant to be wherever the pointer is, so this is the way to
    /// pull it back to one screen, not the way to ask for the rest.
    var showOnAllDisplays: Bool {
        get { value.showOnAllDisplays }
        set { value.showOnAllDisplays = newValue; persist() }
    }

    /// Off switch for people who copy images all day and do not want them
    /// kept. Defaults to on: the feature is the reason the folder exists.
    var saveClipboardImages: Bool {
        get { value.saveClipboardImages }
        set { value.saveClipboardImages = newValue; persist() }
    }

    /// Raw `PrivacyMode.Section` values. Kept as strings here rather than that
    /// type so this store does not need to know about it — the same reason
    /// `hiddenTabs` below is `[String]` and not `[NotchViewModel.Tab]`.
    var privacy: [String] {
        get { value.privacy }
        set { value.privacy = newValue; persist() }
    }

    var teleprompterSpeed: Double {
        get { value.teleprompter.speed }
        set { value.teleprompter.speed = newValue; persist() }
    }

    var teleprompterFontSize: Double {
        get { value.teleprompter.fontSize }
        set { value.teleprompter.fontSize = newValue; persist() }
    }

    /// Tabs switched off in Settings (#80), by `Tab.rawValue`. Kept as the set
    /// of what is off rather than what is on, so a tab added in a later
    /// version shows up for everyone instead of arriving hidden.
    var hiddenTabs: [String] {
        get { value.hiddenTabs }
        set { value.hiddenTabs = newValue; persist() }
    }

    // MARK: - Migration

    /// Reads the five places these settings used to live. Each guard mirrors
    /// exactly what that setting's own `object(forKey:) != nil` check used to
    /// do, so a Mac with none of these keys set gets the same defaults as
    /// before and a Mac with some of them set keeps exactly those.
    private static func migrated() -> File {
        let defaults = UserDefaults.standard
        var file = File()
        if defaults.object(forKey: "showOnAllDisplays") != nil {
            file.showOnAllDisplays = defaults.bool(forKey: "showOnAllDisplays")
        }
        if defaults.object(forKey: "saveClipboardImages") != nil {
            file.saveClipboardImages = defaults.bool(forKey: "saveClipboardImages")
        }
        if let sections = defaults.array(forKey: "privacyMode.sections") as? [String] {
            file.privacy = sections
        } else if defaults.bool(forKey: "privacyMode") {
            // The legacy switch covered everything or nothing — see
            // `PrivacyMode.init` before this store existed.
            file.privacy = ["clipboard", "snippets", "calendar", "notes"]
        }
        if let speed = defaults.object(forKey: "teleprompter.speed") as? Double {
            file.teleprompter.speed = speed
        }
        if let fontSize = defaults.object(forKey: "teleprompter.fontSize") as? Double {
            file.teleprompter.fontSize = fontSize
        }
        if let hidden = defaults.stringArray(forKey: "hiddenTabs") {
            file.hiddenTabs = hidden
        }
        return file
    }

    // MARK: - Storage

    private func persist() {
        write(value)
    }

    /// Pretty-printed, and slashes left alone — same reason as
    /// `snippets.json`: this file is meant to be opened, edited by hand, and
    /// handed to somebody else's Mac.
    private func write(_ file: File) {
        guard !fileBroken else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(file).write(to: Self.file, options: .atomic)
        } catch {
            NSLog("Cyclop: cannot write config.json: \(error.localizedDescription)")
        }
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) {
            shared.write(shared.value)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
