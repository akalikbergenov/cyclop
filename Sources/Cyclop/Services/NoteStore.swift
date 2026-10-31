import AppKit

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var edited: Date
}

/// Scratch notes: somewhere to put a thought down for an hour.
///
/// Deliberately not a notes app. No folders, no formatting, no search — for
/// that there are real editors. This replaces the unsaved buffer people keep
/// in one: a phone number from a call, half a link, a thought to come back to
/// — written fast, then deleted or carried off through the clipboard.
///
/// Everything here is shaped by that shortness of life: notes are created
/// empty and instantly, deleted in one click, and the blank ones sweep
/// themselves out when the tab is left. The file they live in is an
/// implementation detail — unlike the snippets file, nobody is expected to
/// edit it by hand.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    /// Which note the editor shows. Lives here rather than in the pane so the
    /// choice survives the pane being unmounted with the panel.
    @Published var selected: Note.ID?
    /// True when `notes.json` exists but cannot be read. Writing then stops:
    /// a file that failed to parse still holds the notes, and the first
    /// keystroke used to write an empty list over them. Same rule as
    /// `SnippetStore.fileBroken` (#7).
    @Published private(set) var fileBroken = false

    /// Where the notes live. Injectable for the same reason as
    /// `SnippetStore.file`: a fixed path means the only way to test loading
    /// and writing is to write into the real support folder — somebody's
    /// actual notes. The app never passes anything but the default.
    let file: URL

    private let saves = DebouncedWrite()

    init(file: URL = Support.file("notes.json")) {
        self.file = file
        load()
    }

    // MARK: - Editing

    /// A new empty note, selected and ready to type into. Newest on top, and
    /// the order never changes afterwards: a list that reshuffles itself on
    /// every edit loses the reader's place for tidiness nobody asked for.
    func add() {
        let note = Note(id: UUID(), text: "", edited: Date())
        notes.insert(note, at: 0)
        selected = note.id
        scheduleSave()
    }

    func update(_ id: Note.ID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        notes[index].edited = Date()
        scheduleSave()
    }

    func remove(_ id: Note.ID) {
        notes.removeAll { $0.id == id }
        if selected == id { selected = notes.first?.id }
        scheduleSave()
    }

    /// Called when the user leaves the tab: notes that never got any text
    /// sweep themselves out. They cost one hover to recreate, and a trail of
    /// blank cards is exactly the clutter a scratchpad exists to avoid.
    func leave() {
        notes.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let selected, !notes.contains(where: { $0.id == selected }) {
            self.selected = notes.first?.id
        }
        flush()
    }

    // MARK: - Persistence

    private func load() {
        // No file is an honest empty list.
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            notes = try JSONDecoder().decode([Note].self, from: data)
            fileBroken = false
            selected = notes.first?.id
        } catch {
            fileBroken = true
            NSLog("Cyclop: notes.json is not readable: \(error.localizedDescription)")
        }
    }

    /// Tries the broken file again, on the next visit to the tab — it may have
    /// been mended by hand meanwhile. What was typed in the meantime is kept
    /// and goes on top of what the file holds.
    func retryIfBroken() {
        guard fileBroken else { return }
        let typed = notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        load()
        guard !fileBroken else { return }
        let known = Set(notes.map(\.id))
        notes.insert(contentsOf: typed.filter { !known.contains($0.id) }, at: 0)
        selected = notes.first?.id
        if !typed.isEmpty { scheduleSave() }
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// A moment after the typing pauses, not on every keystroke: the text
    /// lives in memory either way, and the file only has to be right by the
    /// time somebody could read it.
    private func scheduleSave() {
        saves.schedule { [weak self] in self?.persist() }
    }

    func flush() { saves.flush() }

    private func persist() {
        guard !fileBroken else {
            NSLog("Cyclop: refusing to write over an unreadable notes.json")
            return
        }
        do {
            try JSONEncoder().encode(notes).write(to: file, options: .atomic)
        } catch {
            NSLog("Cyclop: cannot write notes.json: \(error.localizedDescription)")
        }
    }
}
