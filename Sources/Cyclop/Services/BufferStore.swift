import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Marker Cyclop puts on pasteboard writes of its own.
    static let cyclopInternal = NSPasteboard.PasteboardType("com.cyclop.internal")
}

/// One thing that was copied, or dropped in.
///
/// Text and files in one type, because they were one thing all along: what the
/// clipboard held. Splitting them across two tabs meant a copied picture landed
/// somewhere other than a copied word, and remembering which was which was work
/// the app was making for the user rather than saving them.
///
/// An image is a file. A screenshot copied to the clipboard exists only in
/// memory — paste it once and it is gone — so it is written to disk on the way
/// in and from then on is a file like any other, draggable into a Finder window
/// and openable in Preview.
struct BufferItem: Identifiable, Equatable {
    enum Payload: Equatable {
        case text(String)
        case file(URL)
    }

    let id = UUID()
    let payload: Payload
    let date: Date
    /// Files only, and only once QuickLook has rendered one — a list of
    /// identical PNG icons is useless when what it holds is screenshots. Starts
    /// as the file-type icon.
    var icon: NSImage?
    /// Where it came from: the application that was in front when the copy
    /// happened. Half of what identifies an entry in a long list is where it
    /// came from — two identical-looking snippets of code are told apart by one
    /// being from the terminal and the other from the browser.
    var source: BufferSource?

    var url: URL? {
        guard case .file(let url) = payload else { return nil }
        return url
    }

    var isFile: Bool { url != nil }

    var text: String? {
        guard case .text(let string) = payload else { return nil }
        return string
    }

    var preview: String {
        switch payload {
        case .text(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .file(let url):
            return url.lastPathComponent
        }
    }

    var symbol: String {
        switch payload {
        case .text(let string):
            if string.hasPrefix("http://") || string.hasPrefix("https://") { return "link" }
            return "text.alignleft"
        case .file(let url):
            guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .movie) { return "film" }
            if type.conforms(to: .audio) { return "waveform" }
            return "doc"
        }
    }

    /// Identity is what the entry *is*, not when it arrived: copying the same
    /// thing twice moves the one entry back to the top instead of laying a
    /// second copy on the first.
    static func == (lhs: BufferItem, rhs: BufferItem) -> Bool { lhs.payload == rhs.payload }
}

/// The application an entry came from.
///
/// Named and identified separately: the name is what the row shows and is
/// stored with the entry, and the bundle identifier is what finds the icon
/// again after a relaunch — an app's icon is far too big to keep in a list of
/// copies, and looking it up costs a path lookup the system has cached anyway.
struct BufferSource: Equatable, Codable {
    var name: String
    var bundleID: String?

    /// The frontmost application right now, which at the moment a copy is
    /// noticed is the one it came from.
    ///
    /// Nil for our own copies: an entry put back on the pasteboard from the
    /// buffer, or a screenshot taken by the shot editor, did not come from
    /// anywhere the user would call a source.
    @MainActor
    static func current() -> BufferSource? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let name = app.localizedName else { return nil }
        return BufferSource(name: name, bundleID: app.bundleIdentifier)
    }

    /// The application's icon, or nil when it is not installed any more.
    @MainActor
    var icon: NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// The buffer: everything copied or dropped in, newest first.
///
/// A singleton, and the one place this history exists. It used to hang off the
/// view model, which is thrown away and rebuilt whenever the display
/// arrangement changes — so plugging in a monitor silently emptied the
/// clipboard history. With the panel's own size now adjustable, that rebuild
/// happens on a stepper press, and the bug would have been unmissable.
@MainActor
final class BufferStore: ObservableObject {
    static let shared = BufferStore()

    @Published private(set) var items: [BufferItem] = []
    /// Cards picked for a group drag. Empty means "drag whatever is grabbed".
    @Published private(set) var selection: Set<UUID> = []

    private var timer: Timer?
    private var started = false
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let settings = Settings.shared

    private let storeKey = "buffer.items"
    /// What the shelf wrote before the two lists became one. Read once, so an
    /// update does not look like somebody emptied the shelf.
    private let legacyShelfKey = "shelf.urls"

    /// Types an app sets to keep a copy out of history tools. Presence is what
    /// counts, not content: a type can be declared with data that is still on
    /// its way, and asking for the bytes would then answer nil for a password
    /// that is about to arrive. `ConcealedType` is what password managers set;
    /// the other two mark copies made by a machine rather than by a hand.
    private let optOut: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    private init() {}

    // MARK: - Lifecycle

    /// Started once, by the app, and left running.
    ///
    /// Deliberately not tied to the panel: the panel is rebuilt whenever the
    /// display arrangement or its own size changes, and a history that started
    /// and stopped with it would re-read itself from disk on every rebuild —
    /// throwing away exactly the copies that had not been written down.
    func start() {
        guard !started else { return }
        started = true
        load()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // The half-second is a ceiling, not a beat: nobody notices a copy
        // landing in history a fifth of a second late, and the slack lets the
        // system fold this wake-up into others.
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Contents

    func clear() {
        items.removeAll()
        selection.removeAll()
        persist()
    }

    func remove(_ item: BufferItem) {
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        persist()
    }

    /// Files dropped onto the notch, or an image just written to disk.
    func add(_ urls: [URL], source: BufferSource? = nil) {
        let source = source ?? BufferSource.current()
        for url in urls.reversed() {
            record(BufferItem(payload: .file(url), date: Date(), source: source))
        }
        persist()
    }

    /// Drops entries whose file is gone — emptying the screenshots folder from
    /// the menu bar takes the pictures with it, and rows pointing at nothing
    /// must not wait for a relaunch to notice.
    func dropMissingFiles() {
        let fm = FileManager.default
        let gone = items.filter { url in
            guard let path = url.url?.path else { return false }
            return !fm.fileExists(atPath: path)
        }
        guard !gone.isEmpty else { return }
        let ids = Set(gone.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        persist()
    }

    /// Trims to a limit the user can move. Called on every insertion and again
    /// when the number itself changes, so lowering it takes effect at once
    /// rather than at the next copy.
    func applyLimit() {
        let limit = settings.bufferLimit
        guard items.count > limit else { return }
        let dropped = items.suffix(items.count - limit)
        selection.subtract(dropped.map(\.id))
        items.removeLast(items.count - limit)
        persist()
    }

    /// Puts an entry back on the pasteboard without re-recording it.
    ///
    /// A file goes on as a file *and*, when it is a picture, as the picture —
    /// so ⌘V lands a file in the Finder and the image itself in an editor,
    /// whichever the user meant.
    func copy(_ item: BufferItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.payload {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .file(let url):
            // Tells the poller below that this change came from us, so a
            // screenshot put back on the clipboard is not saved to disk a
            // second time.
            pasteboard.setData(Data(), forType: .cyclopInternal)
            pasteboard.writeObjects([url as NSURL])
            if let type = UTType(filenameExtension: url.pathExtension),
               type.conforms(to: .image),
               let data = try? Data(contentsOf: url) {
                // Declared as what the bytes are, not renamed to TIFF:
                // consumers that trust the declared type would save a "TIFF"
                // with JPEG inside (#9). The UTI is the pasteboard type.
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            }
        }
        lastChangeCount = pasteboard.changeCount
        // Freshly used entries bubble to the top.
        if let index = items.firstIndex(where: { $0.id == item.id }), index != 0 {
            let item = items.remove(at: index)
            items.insert(item, at: 0)
            persist()
        }
    }

    func open(_ item: BufferItem) {
        guard let url = item.url else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: BufferItem) {
        guard let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Selection

    /// Plain click replaces the selection; ⌘ or ⇧ adds to it, matching Finder.
    /// Files only — there is nothing to drag a piece of text out into.
    func select(_ item: BufferItem, modifiers: NSEvent.ModifierFlags) {
        guard item.isFile else { return }
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else if selection == [item.id] {
            selection.removeAll()
        } else {
            selection = [item.id]
        }
    }

    func isSelected(_ item: BufferItem) -> Bool { selection.contains(item.id) }

    func clearSelection() { selection.removeAll() }

    /// Files a drag started on `item` should carry: the whole selection when
    /// the grabbed row belongs to it, otherwise just that row.
    func dragURLs(startingAt item: BufferItem) -> [URL] {
        guard let url = item.url else { return [] }
        guard selection.contains(item.id) else { return [url] }
        return items.filter { selection.contains($0.id) }.compactMap(\.url)
    }

    // MARK: - Watching the pasteboard

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard pasteboard.availableType(from: optOut) == nil else { return }
        // Our own write — putting an entry back must not record it again.
        guard pasteboard.data(forType: .cyclopInternal) == nil else { return }

        // A copied file arrives as a URL, not as image data, so URLs win first.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let source = BufferSource.current()

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            add(urls, source: source)
            return
        }

        if settings.saveImages {
            if let png = pngFromPasteboard(pasteboard) {
                saveImage(png, source: source)
                return
            }

            // A copy made on the phone arrives in two parts: macOS puts the
            // type on the pasteboard the moment the phone announces it, and
            // the picture itself is still coming over the air. So the counter
            // can move while there are no bytes to read yet — and reading once
            // would drop the screenshot for good, because the counter has
            // already been marked as seen. Wait for it instead.
            if pasteboard.availableType(from: [.png, .tiff]) != nil {
                awaitImage(at: pasteboard.changeCount, attempt: 0)
                return
            }
        }

        guard let string = pasteboard.string(forType: .string),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        record(BufferItem(payload: .text(string), date: Date(), source: source))
        persist()
    }

    /// Checks back until the promised picture has actually arrived.
    ///
    /// Gives up after a few seconds, and stops the moment the pasteboard moves
    /// on: a copy made in the meantime is the newer intention, and finishing a
    /// transfer the user has already replaced would put the wrong thing here.
    private func awaitImage(at changeCount: Int, attempt: Int) {
        // Out of patience. Something declared a picture and never produced one,
        // so fall back to what else was on the pasteboard — otherwise a copy
        // that merely offered an image alongside its text would go unrecorded.
        guard attempt < 12 else {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCount,
                  let string = pasteboard.string(forType: .string),
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            record(BufferItem(payload: .text(string), date: Date()))
            persist()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount == changeCount else { return }
                if let png = self.pngFromPasteboard(pasteboard) {
                    self.saveImage(png, source: BufferSource.current())
                    return
                }
                self.awaitImage(at: changeCount, attempt: attempt + 1)
            }
        }
    }

    /// Screenshots land as PNG; other apps often offer only TIFF.
    private func pngFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func saveImage(_ png: Data, source: BufferSource? = nil) {
        guard let url = ScreenshotVault.save(png) else { return }
        add([url], source: source)
    }

    // MARK: - Insertion

    private func record(_ item: BufferItem) {
        items.removeAll { $0 == item }
        items.insert(item, at: 0)
        if item.isFile { loadThumbnail(item) }
        let limit = settings.bufferLimit
        if items.count > limit {
            let dropped = items.suffix(items.count - limit)
            selection.subtract(dropped.map(\.id))
            items.removeLast(items.count - limit)
        }
    }

    private func loadThumbnail(_ item: BufferItem) {
        guard let url = item.url else { return }
        // A box QuickLook fits the content into, whatever its shape. Generous
        // enough that a landscape screenshot still lands above the row's pixel
        // size once it has been fitted.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            // `nsImage` already carries the right point size for the
            // representation; deriving one from `contentRect` risks describing
            // a shape the bitmap does not have.
            let image = rep.nsImage
            Task { @MainActor in
                guard let self, let index = self.items.firstIndex(where: { $0.url == url }) else { return }
                self.items[index].icon = image
            }
        }
    }

    // MARK: - Disk

    /// What is written down, and what is not.
    ///
    /// Files always: they are references to things already on disk, and a list
    /// of paths gives away nothing the disk was not already holding. Text only
    /// if the user has said so in Settings — see `keepTextBetweenLaunches`.
    private struct Stored: Codable {
        var kind: String
        var value: String
        var date: Date
        var source: BufferSource?
    }

    private func persist() {
        var stored: [Stored] = []
        for item in items {
            switch item.payload {
            case .file(let url):
                stored.append(Stored(kind: "file", value: url.path, date: item.date, source: item.source))
            case .text(let string):
                guard settings.keepTextBetweenLaunches else { continue }
                stored.append(Stored(kind: "text", value: string, date: item.date, source: item.source))
            }
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    /// Re-persists everything under the current rules. Called when the "keep
    /// text" switch is thrown, in both directions: turning it on has to write
    /// what is already in the list, and turning it off has to take the text
    /// back off the disk right then — not at the next copy.
    func rewrite() {
        persist()
    }

    private func load() {
        let defaults = UserDefaults.standard
        let fm = FileManager.default

        if let data = defaults.data(forKey: storeKey),
           let stored = try? JSONDecoder().decode([Stored].self, from: data) {
            items = stored.compactMap { entry in
                switch entry.kind {
                case "file":
                    let url = URL(fileURLWithPath: entry.value)
                    // A file that has been moved or thrown away since is not
                    // an entry any more; nothing is deleted here, it is simply
                    // no longer there to point at.
                    guard fm.fileExists(atPath: url.path) else { return nil }
                    return BufferItem(
                        payload: .file(url),
                        date: entry.date,
                        icon: NSWorkspace.shared.icon(forFile: url.path),
                        source: entry.source
                    )
                case "text":
                    guard settings.keepTextBetweenLaunches else { return nil }
                    return BufferItem(payload: .text(entry.value), date: entry.date, source: entry.source)
                default:
                    return nil
                }
            }
        } else if let paths = defaults.stringArray(forKey: legacyShelfKey) {
            // Straight from the old shelf, once.
            items = paths
                .filter { fm.fileExists(atPath: $0) }
                .map { path in
                    let url = URL(fileURLWithPath: path)
                    return BufferItem(
                        payload: .file(url),
                        date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? Date(),
                        icon: NSWorkspace.shared.icon(forFile: path)
                    )
                }
            defaults.removeObject(forKey: legacyShelfKey)
            persist()
        }

        applyLimit()
        items.forEach(loadThumbnail)
    }
}
