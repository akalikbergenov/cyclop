import AppKit

struct Snippet: Identifiable, Codable, Equatable {
    /// Name and value together, not the name alone.
    ///
    /// The name by itself made two snippets called the same thing one snippet:
    /// SwiftUI lists rows by identity, so the newer silently replaced the older
    /// — and a password and a staging password both called `nox-password` is a
    /// perfectly reasonable pair to want.
    ///
    /// A separate stored id would do the same job, but this file is meant to be
    /// opened and edited by hand — hence the pretty printing and the unescaped
    /// slashes — and technical ids in it would be one more thing to keep
    /// correct while doing that, plus something hand-written rows would lack.
    /// A full duplicate, same name and same value, still collapses into one,
    /// which is the only case where collapsing is right.
    var id: String { "\(label)\u{0}\(text)" }
    /// Optional name. Without one the row shows the value itself, which is
    /// usually enough for an address or a phone number.
    var label: String = ""
    var text: String

    /// Guessed from the value, so a row is recognisable before it is read.
    var symbol: String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("@"), !value.contains(" ") { return "at" }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return "link" }
        let digits = value.filter(\.isNumber).count
        if digits >= 7, value.allSatisfy({ $0.isNumber || " +-()".contains($0) }) { return "phone.fill" }
        return "text.alignleft"
    }

    private enum CodingKeys: String, CodingKey { case label, text }

    init(label: String = "", text: String) {
        self.label = label
        self.text = text
    }

    /// `label` may be absent from the file — the documented format allows it,
    /// and `encode(to:)` below writes it that way. The synthesized decoder
    /// treated the key as required, so one unnamed snippet made the whole
    /// array unreadable: the tab showed empty, and the next addition wrote
    /// that emptiness over the file (#14).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        text = try container.decode(String.self, forKey: .text)
    }

    /// An unnamed snippet is written without the key rather than with an empty
    /// one: the file is documented as taking `label` or leaving it out, and
    /// what the app writes should look like what it asks people to write.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !label.isEmpty { try container.encode(label, forKey: .label) }
        try container.encode(text, forKey: .text)
    }
}

/// A hand-kept list of things worth not retyping.
///
/// Deliberately not fed by the clipboard: the clipboard is a queue ordered by
/// recency, which loses exactly the entry used once a month, and anything
/// automatic would fill this with whatever happened to pass through. What
/// belongs here is decided by hand — from the panel or in the file, whichever
/// is closer at the time. Both edit the same list.
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var items: [Snippet] = []
    @Published var query = ""
    /// True when the file exists but cannot be parsed — a hand edit left it
    /// broken. The one state in which writing is forbidden: "could not read"
    /// and "read as it is" are different answers, and only the second makes
    /// writing back safe (#7).
    @Published private(set) var fileBroken = false

    /// Matches the name and the value alike: one remembers an address either by
    /// what it is called or by what is in it, rarely reliably by both.
    var filtered: [Snippet] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.label.matches(needle) || $0.text.matches(needle) }
    }

    /// `~/Library/Application Support/Cyclop/snippets.json`. A plain array of
    /// `{"label": "...", "text": "..."}`, where `label` may be left out.
    static let file = Support.file("snippets.json")

    /// Re-read on every visit to the tab. The file is edited from outside the
    /// app, so the only sensible moment to trust what is in memory is the
    /// moment before it is shown.
    func reload() {
        guard let data = try? Data(contentsOf: Self.file) else {
            // No file is an honest empty list, and writing one is safe.
            items = []
            fileBroken = false
            return
        }
        do {
            items = try JSONDecoder().decode([Snippet].self, from: data)
            fileBroken = false
        } catch {
            // The file exists and says something — it just cannot be read.
            // Keep whatever was on screen, raise the flag, and let the pane
            // say so: silence here is what used to turn a stray comma into a
            // lost file.
            fileBroken = true
            NSLog("Cyclop: snippets.json is not readable: \(error.localizedDescription)")
        }
    }

    /// Adds one and writes the file.
    ///
    /// Re-reads first, because the file is also edited by hand and the copy in
    /// memory is only as fresh as the last visit to the tab. Writing over it
    /// blind would silently undo whatever was added in an editor meanwhile.
    func add(label: String, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let snippet = Snippet(label: label.trimmingCharacters(in: .whitespacesAndNewlines), text: value)
        reload()
        // A file that could not be read must not be written. The snippet is
        // dropped rather than kept in memory as if saved: pretending would
        // trade a visible refusal now for a silent loss at relaunch.
        guard !fileBroken else {
            NSLog("Cyclop: refusing to write over an unreadable snippets.json")
            return
        }
        // Only an exact duplicate — same name and same value — is dropped, and
        // it is dropped because two identical rows are indistinguishable in the
        // list anyway. Two snippets sharing a name but not a value are kept
        // apart: see `Snippet.id`.
        items.removeAll { $0.id == snippet.id }
        items.insert(snippet, at: 0)
        persist()
    }

    func remove(_ snippet: Snippet) {
        items.removeAll { $0.id == snippet.id }
        persist()
    }

    /// Moves a snippet to another position and writes the new order.
    ///
    /// The order is the file's order, so dragging a row is a real edit and not
    /// a view-only arrangement — the one people reach for is meant to end up on
    /// top and stay there.
    ///
    /// Unlike `add` and `update`, this does not re-read the file first: a drag
    /// is a continuous gesture, and re-reading mid-gesture would swap the list
    /// out from under the row being dragged.
    func move(_ snippet: Snippet, to index: Int) {
        guard let current = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        let target = max(0, min(index, items.count - 1))
        guard target != current else { return }
        items.insert(items.remove(at: current), at: target)
        persist()
    }

    /// Edits a snippet in place, keeping its position in the list.
    ///
    /// Not `remove` plus `add`: identity here is the name, so renaming makes a
    /// different snippet as far as the list is concerned, and adding puts it on
    /// top. A row edited in place would then jump to the front the moment its
    /// name changed — while the person is still looking at it.
    ///
    /// An emptied value cancels the edit rather than deleting the row. Deleting
    /// already has its own ✕, and losing a snippet to a stray ⌘A is a poor
    /// trade for saving a press.
    func update(_ snippet: Snippet, label: String, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let edited = Snippet(label: label.trimmingCharacters(in: .whitespacesAndNewlines), text: value)
        guard edited != snippet else { return }

        reload()
        // A file that could not be read must not be written over.
        guard !fileBroken else {
            NSLog("Cyclop: refusing to write over an unreadable snippets.json")
            return
        }
        // An edit that turns this row into an exact copy of another one leaves
        // a single row, for the same reason `add` does.
        items.removeAll { $0.id == edited.id && $0.id != snippet.id }
        // Found after the removal, never before it: a copy standing above this
        // row shifts it up by one, and an index taken beforehand then points at
        // the neighbour. Written there, the edit destroys a snippet nobody
        // touched and leaves the edited one exactly as it was.
        guard let index = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        items[index] = edited
        persist()
    }

    /// Pretty-printed, and slashes left alone: the file is meant to be opened
    /// and edited by hand, and `\/` in every URL would be the app making that
    /// harder for its own convenience.
    private func persist() {
        guard !fileBroken else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(items).write(to: Self.file, options: .atomic)
        } catch {
            NSLog("Cyclop: cannot write snippets.json: \(error.localizedDescription)")
        }
    }

    /// Puts a snippet on the pasteboard, ready to paste.
    ///
    /// The pasteboard is the only way to hand text to another app without
    /// asking for Accessibility, which this app is built not to do. Whatever
    /// was there is overwritten, and stays available in the clipboard tab.
    func copy(_ snippet: Snippet) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet.text, forType: .string)
    }

    /// Selecting a file that is not on disk yet is a silent no-op for Finder —
    /// nothing opens, nothing errors. Before the first snippet is added there
    /// is nothing to select, so an empty list is written first: the same
    /// state `reload()` already treats as a valid, empty file.
    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Data("[]".utf8).write(to: file)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}

private extension String {
    /// Case- and accent-blind, so "почта" finds "Почта" and "Nagy" finds "Nagy".
    func matches(_ needle: String) -> Bool {
        range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
