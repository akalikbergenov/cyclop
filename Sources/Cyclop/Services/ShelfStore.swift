import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Marker Cyclop puts on pasteboard writes of its own.
    static let cyclopInternal = NSPasteboard.PasteboardType("com.cyclop.internal")
}

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Starts as the file-type icon and is replaced by a real preview once
    /// QuickLook renders one — a shelf of identical PNG icons is useless when
    /// what it holds is screenshots.
    var icon: NSImage
    var name: String { url.lastPathComponent }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.url == rhs.url }
}

/// Drop zone contents. Files are referenced, never copied — the shelf is a
/// holding area, so moving the original away simply removes it from the shelf.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// Cards picked for a group drag. Empty means "drag whatever is grabbed".
    @Published private(set) var selection: Set<UUID> = []

    private let defaultsKey = "shelf.urls"
    /// Generous, because saved screenshots accumulate here and nothing is
    /// deleted behind the user's back. Cards past the limit leave the shelf,
    /// but their files stay in the folder.
    private let limit = 60

    /// Rebuilds the cards from the stored paths without reading a single file.
    ///
    /// Nothing here touches the disk, and that is the whole point. Since
    /// Catalina, the first look at anything inside Desktop, Documents or
    /// Downloads raises a system permission prompt — for `stat` as much as for
    /// a read — and this used to run at launch, for every card, whether or not
    /// anyone was going to open the shelf. One file dragged in from Downloads
    /// months ago meant a dialog on every cold start, arriving with no visible
    /// cause: the panel was not even open. Cyclop promises no permissions until
    /// the calendar is opened, and this quietly broke that promise.
    ///
    /// So the icon comes from the file *name* — the extension is enough to
    /// name a type, and a type is enough to draw an icon — and whether the file
    /// is still there is not asked until someone looks at the shelf.
    func load() {
        // Card ids are minted per instance, so a reload orphans any selection:
        // the ids it holds now name nothing. Kept, they showed as a phantom
        // "Selected: N" in the footer with no card marked (#10).
        selection.removeAll()
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        items = paths
            .map(URL.init(fileURLWithPath:))
            .map { ShelfItem(url: $0, icon: Self.icon(forName: $0)) }
    }

    /// An icon for a path, derived from its extension alone.
    private static func icon(forName url: URL) -> NSImage {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// Called when the shelf comes into view, and only then.
    ///
    /// This is where the disk is finally touched: missing files leave, real
    /// icons and previews arrive. If a permission prompt is coming, it comes
    /// here — with the shelf on screen and the cards in front of the person
    /// being asked, which is the difference between a question and an
    /// interruption.
    func refreshFromDisk() {
        guard !items.isEmpty else { return }
        let gone = Set(items.filter { Self.isGone($0.url) }.map(\.id))
        if !gone.isEmpty {
            items.removeAll { gone.contains($0.id) }
            selection.subtract(gone)
            persist()
        }
        items.forEach(loadThumbnail)
    }

    /// Whether the file is actually gone, as opposed to merely out of reach.
    ///
    /// `fileExists` answers false to both, and the difference matters: a card
    /// whose file was deleted should leave the shelf, while one the app was
    /// just refused access to should stay exactly where it is. Treating them
    /// alike meant a single "Don't Allow" silently emptied the shelf of
    /// everything kept in Downloads, with the files still sitting there.
    private static func isGone(_ url: URL) -> Bool {
        do {
            return try !url.checkResourceIsReachable()
        } catch let error as NSError {
            return error.code == NSFileReadNoSuchFileError
        }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = ShelfItem(url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
            items.insert(item, at: 0)
            loadThumbnail(item)
        }
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    private func loadThumbnail(_ item: ShelfItem) {
        // A square box QuickLook fits the content into, whatever its shape.
        // Generous enough that a landscape screenshot still lands above the
        // card's pixel size once it has been fitted.
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
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
                guard let self, let index = self.items.firstIndex(where: { $0.url == item.url }) else { return }
                self.items[index].icon = image
            }
        }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        persist()
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
        persist()
    }

    // MARK: - Selection

    /// Plain click replaces the selection; ⌘ or ⇧ adds to it, matching Finder.
    ///
    /// The pasteboard then mirrors whatever ended up selected. ⌘C cannot do this
    /// job here: the panel only takes the keyboard on tabs with a field, and
    /// claiming it for the shelf would dim the window underneath for as long as
    /// the shelf is open. Picking a card is the whole gesture instead — the
    /// shelf exists to hand a file onward.
    ///
    /// Mirroring, precisely: a ⌘-click that drops one card of three rewrites the
    /// pasteboard with the remaining two, because a selection on screen that
    /// disagrees with what would be pasted is worse than either. Only clearing
    /// the selection entirely leaves the pasteboard alone — an empty write would
    /// take back what was copied and hand over nothing. A double click passes
    /// through here first, with `clickCount == 1`, so opening a card copies it
    /// on the way.
    func select(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
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
        copySelection()
    }

    func isSelected(_ item: ShelfItem) -> Bool { selection.contains(item.id) }

    func clearSelection() { selection.removeAll() }

    /// Files a drag started on `item` should carry: the whole selection when
    /// the grabbed card belongs to it, otherwise just that card.
    func dragURLs(startingAt item: ShelfItem) -> [URL] {
        guard selection.contains(item.id) else { return [item.url] }
        return items.filter { selection.contains($0.id) }.map(\.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Puts the card back on the pasteboard. Images go as image data as well as
    /// a file reference, so pasting works both in Finder and in an editor.
    func copy(_ item: ShelfItem) {
        copy([item.url])
    }

    /// The current selection, as one pasteboard write.
    func copySelection() {
        copy(items.filter { selection.contains($0.id) }.map(\.url))
    }

    /// One pasteboard item per file, plus the paths as plain text.
    ///
    /// Picture bytes go along only when a single card was copied. A reader that
    /// finds an image takes it and looks no further, so attaching a picture to a
    /// copy of several files turns "four screenshots" into "the first
    /// screenshot". Left without one, such a reader falls through to the text
    /// and gets every path; whoever enumerates the items was taking all the
    /// files either way.
    private func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // The file goes on first and everything below is added to the item it
        // creates. Order is the whole of it: `setData` always writes to the
        // first item, `writeObjects` appends a new one — so marking first put
        // the picture on one item and the file on another. One card then
        // arrives as two objects, and an editor that accepts both pastes the
        // screenshot twice.
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        // Tells ClipboardStore this change came from us, so a copied screenshot
        // is not saved to disk a second time.
        pasteboard.setData(Data(), forType: .cyclopInternal)
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        if urls.count == 1, let url = urls.first,
           let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image),
           let data = try? Data(contentsOf: url) {
            // Declared as what the bytes are, not renamed to TIFF: consumers
            // that trust the declared type would save a "TIFF" with JPEG
            // inside (#9). The UTI is already the pasteboard type identifier.
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: defaultsKey)
    }
}
