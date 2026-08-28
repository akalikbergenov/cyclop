import AppKit

struct SavedPost: Identifiable, Codable, Equatable {
    let id: UUID
    var url: URL
    /// Without the `@`. Absent when the copied link was an `/i/status/…` form.
    var handle: String?
    var statusID: String
    var savedAt: Date
    var note: String
    var isRead: Bool

    /// What the row leads with: the author when the URL named one.
    var title: String {
        if let handle { return "@\(handle)" }
        return localized("Post")
    }
}

/// Posts saved for later. Copying a post's link on X is the whole gesture:
/// the clipboard watcher hands every copied text here, and the ones that are
/// post links stay. Everything else falls through untouched.
///
/// Unlike the clipboard history, which lives and dies with the process, this
/// list is the point of the feature — it survives restarts, in a file a person
/// can open and read.
@MainActor
final class PostStore: ObservableObject {
    @Published private(set) var items: [SavedPost] = []
    @Published var query = ""
    /// True when the file exists but cannot be parsed. The one state in which
    /// writing is forbidden: "could not read" and "read as it is" are
    /// different answers, and only the second makes writing back safe.
    @Published private(set) var fileBroken = false

    /// `~/Library/Application Support/Cyclop/posts.json`.
    static let file = Support.file("posts.json")

    private let saves = DebouncedWrite()
    /// Generous: rows are one line each, and nothing here is deleted behind
    /// the user's back until the list is this long.
    private let limit = 200

    /// Off switch, shared with the Settings tab: off removes the tab from the
    /// rail and stops capture with it — a feature switched off should not keep
    /// collecting in the background.
    static let enabledKey = "posts.enabled"

    /// Defaults to on: the tab is how anyone learns the feature exists.
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    init() {
        load()
    }

    /// Matches the handle and the note alike — one remembers a post either by
    /// who wrote it or by what one wrote about it.
    var filtered: [SavedPost] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { post in
            post.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || post.note.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// What the header counter shows: the posts not yet returned to.
    var unreadCount: Int { items.count(where: { !$0.isRead }) }

    // MARK: - Capture

    /// Every copied text passes through here; only post links stay.
    ///
    /// A link already saved bubbles back to the top with its note and read
    /// state intact — copying it again means it matters again, not that the
    /// annotation stopped being true.
    func capture(_ text: String) {
        guard let link = PostLink.parse(text) else { return }
        if let index = items.firstIndex(where: { $0.statusID == link.statusID }) {
            guard index != 0 else { return }
            items.insert(items.remove(at: index), at: 0)
        } else {
            let post = SavedPost(
                id: UUID(),
                url: link.url,
                handle: link.handle,
                statusID: link.statusID,
                savedAt: Date(),
                note: "",
                isRead: false
            )
            items.insert(post, at: 0)
            if items.count > limit { items.removeLast(items.count - limit) }
        }
        scheduleSave()
    }

    // MARK: - Actions

    /// Opening is the reading: the browser shows the post, so the dot that
    /// meant "not yet returned to" has done its job.
    func open(_ post: SavedPost) {
        NSWorkspace.shared.open(post.url)
        setRead(post, true)
    }

    /// Puts the canonical link on the pasteboard, marked as Cyclop's own write
    /// so the clipboard history does not record it and this store does not
    /// bubble the post as if it were saved anew.
    func copy(_ post: SavedPost) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(post.url.absoluteString, forType: .string)
        pasteboard.setData(Data(), forType: .cyclopInternal)
    }

    func setRead(_ post: SavedPost, _ read: Bool) {
        guard let index = items.firstIndex(where: { $0.id == post.id }),
              items[index].isRead != read else { return }
        items[index].isRead = read
        scheduleSave()
    }

    func setNote(_ post: SavedPost, _ text: String) {
        guard let index = items.firstIndex(where: { $0.id == post.id }),
              items[index].note != text else { return }
        items[index].note = text
        scheduleSave()
    }

    func remove(_ post: SavedPost) {
        items.removeAll { $0.id == post.id }
        scheduleSave()
    }

    func clear() {
        items.removeAll()
        scheduleSave()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else {
            // No file is an honest empty list, and writing one is safe.
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([SavedPost].self, from: data)
        } catch {
            fileBroken = true
            NSLog("Cyclop: posts.json is not readable: \(error.localizedDescription)")
        }
    }

    /// A moment after the change, not on it: notes arrive per keystroke, and
    /// the file only has to be right by the time somebody could read it.
    private func scheduleSave() {
        guard !fileBroken else {
            NSLog("Cyclop: refusing to write over an unreadable posts.json")
            return
        }
        saves.schedule { [weak self] in self?.persist() }
    }

    func flush() { saves.flush() }

    /// Selecting a file that is not on disk yet is a silent no-op for Finder,
    /// so an empty list is written first — the same state `load()` already
    /// treats as a valid, empty file.
    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Data("[]".utf8).write(to: file)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Pretty-printed with slashes left alone, and dates as dates: the file is
    /// what SECURITY.md points at when it says what is kept, so it should read
    /// as an answer, not as an encoding.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(items).write(to: Self.file, options: .atomic)
        } catch {
            NSLog("Cyclop: cannot write posts.json: \(error.localizedDescription)")
        }
    }
}
