import AppKit

struct SavedPost: Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// Without the `@`. Absent when the link was an `/i/status/…` form.
    let handle: String?
    let statusID: String
    let savedAt: Date
    var note: String
    var isRead: Bool

    init(link: PostLink, id: UUID = UUID(), savedAt: Date = Date(), note: String = "", isRead: Bool = false) {
        self.id = id
        self.url = link.url
        self.handle = link.handle
        self.statusID = link.statusID
        self.savedAt = savedAt
        self.note = note
        self.isRead = isRead
    }

    /// What the row leads with: the author when the URL named one.
    var title: String {
        if let handle { return "@\(handle)" }
        return localized("Post")
    }
}

/// The URL is the record: the author and the id live inside it, so storing
/// them alongside would be three fields for one fact, free to disagree after
/// a hand edit. The file keeps the address; the rest is re-read from it.
extension SavedPost: Codable {
    private enum CodingKeys: String, CodingKey { case id, url, savedAt, note, isRead }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        note = try container.decode(String.self, forKey: .note)
        isRead = try container.decode(Bool.self, forKey: .isRead)
        // An address edited into something that is no longer a post link
        // keeps its row rather than breaking the file: no author, and the
        // whole address as its own identity.
        let link = PostLink.parse(url.absoluteString)
        handle = link?.handle
        statusID = link?.statusID ?? url.absoluteString
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(note, forKey: .note)
        try container.encode(isRead, forKey: .isRead)
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

    /// The off switch, owned here end to end: the Settings tab writes it, the
    /// view model reads it for the rail, and `capture` asks it for itself —
    /// so no future caller can collect for a tab that is switched off.
    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            // Defaults to on: the tab is how anyone learns the feature exists.
            guard defaults.object(forKey: enabledKey) != nil else { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static let enabledKey = "posts.enabled"

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
    /// annotation stopped being true. One exception to "intact": a copy that
    /// names the author upgrades a post first saved through an anonymous
    /// `/i/status/…` link.
    ///
    /// With the file broken, the link is dropped rather than kept in memory
    /// as if saved: a list that looks saved and vanishes at relaunch is the
    /// silent loss the refusal to write exists to prevent.
    func capture(_ text: String) {
        guard Self.isEnabled, !fileBroken,
              let link = PostLink.parse(text) else { return }
        if let index = items.firstIndex(where: { $0.statusID == link.statusID }) {
            let known = items[index]
            let upgrades = known.handle == nil && link.handle != nil
            guard index != 0 || upgrades else { return }
            items.remove(at: index)
            items.insert(
                upgrades
                    ? SavedPost(link: link, id: known.id, savedAt: known.savedAt, note: known.note, isRead: known.isRead)
                    : known,
                at: 0
            )
        } else {
            items.insert(SavedPost(link: link), at: 0)
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

    // MARK: - Persistence

    /// Called on the way into the tab, and only to recover from a broken
    /// file. A healthy file is never re-read — unlike the snippets file it is
    /// not edited by hand as a habit, and a debounced write may be in flight
    /// that a re-read would silently roll back.
    func reload() {
        guard fileBroken else { return }
        fileBroken = false
        load()
    }

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
