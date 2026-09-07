import AppKit
import UniformTypeIdentifiers

/// Watches the folder `screencapture` writes file-based screenshots into —
/// ⌘⇧3/⌘⇧4 without holding Ctrl, which save straight to disk and never touch
/// the pasteboard, so `ClipboardStore` never sees them (#18).
///
/// Off by default and never watches on its own: since Catalina, macOS gates
/// programmatic access to Desktop/Documents/Downloads behind a Privacy
/// prompt for every app, sandboxed or not — the one exception is a folder
/// the user hands over through a standard Open panel, which counts as
/// consent on its own and asks nothing further. `requestAccess` is that
/// panel; nothing here reads the folder before it has been called once and
/// approved.
@MainActor
final class ScreenshotFolderWatcher {
    /// A new screenshot file, ready to go on the shelf.
    var onImage: ((URL) -> Void)?

    private let enabledKey = "screenshotFolderWatch.enabled"
    private let pathKey = "screenshotFolderWatch.path"

    private var source: DispatchSourceFileSystemObject?
    /// Names already accounted for — either seen at watch-start or already
    /// handed to `onImage`. Keeps a rename or a second write to the same
    /// name from being reported twice.
    private var seen: Set<String> = []

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    var folderPath: String? {
        UserDefaults.standard.string(forKey: pathKey)
    }

    /// Where `screencapture` saves files today — read the same preference it
    /// does, so the picker opens on the folder that actually fills up.
    static var systemLocation: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Puts up the Open panel that stands in for a Privacy prompt. Starts
    /// watching immediately on approval; changes nothing on cancel.
    func requestAccess(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.title = localized("Choose Screenshots Folder")
        panel.message = localized(
            "Cyclop will watch this folder for new screenshots and add them to the shelf."
        )
        panel.prompt = localized("Watch")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.systemLocation
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            UserDefaults.standard.set(url.path, forKey: self.pathKey)
            UserDefaults.standard.set(true, forKey: self.enabledKey)
            self.start(at: url)
            completion(true)
        }
    }

    /// Called at launch. Silent — the folder was already granted once, so
    /// resuming asks nothing further.
    func resumeIfEnabled() {
        guard isEnabled, let folderPath else { return }
        start(at: URL(fileURLWithPath: folderPath, isDirectory: true))
    }

    /// The Settings tab's off switch. Clears the grant along with the watch, so
    /// turning it back on goes through the panel again rather than silently
    /// resuming access nobody remembers giving.
    func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
        stop()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func start(at folder: URL) {
        stop()
        seen = Set(entries(in: folder).map(\.lastPathComponent))

        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.scan(folder) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// A directory `.write` event fires for any change to its listing — new
    /// file, rename, delete — so this diffs against `seen` rather than
    /// trusting the event to mean "a screenshot arrived".
    private func scan(_ folder: URL) {
        for url in entries(in: folder) {
            let name = url.lastPathComponent
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image) else { continue }
            waitForStableSize(url, lastSize: -1, attempt: 0)
        }
    }

    /// `screencapture` writes the file in one shot, but checking twice for a
    /// steady size costs nothing and guards against a half-written file on a
    /// slow volume — the same caution `ClipboardStore.awaitImage` uses for
    /// screenshots arriving over Continuity.
    private func waitForStableSize(_ url: URL, lastSize: Int, attempt: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else {
            return
        }
        if size == lastSize && size > 0 {
            onImage?(url)
            return
        }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForStableSize(url, lastSize: size, attempt: attempt + 1)
        }
    }

    private func entries(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
    }
}
