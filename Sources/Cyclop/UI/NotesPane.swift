import SwiftUI

/// Scratch notes: the list on the left, the note itself on the right.
struct NotesPane: View {
    @ObservedObject var notes: NoteStore
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard, so the editor can follow it.
    @Binding var wantsKeyboard: Bool

    @FocusState private var focused: Bool

    /// Per note, like the rows in the other tabs. A curtain over the whole tab
    /// would also cover the only thing here that is not the text — which note
    /// is which — and leave no way to pick one without uncovering it.
    private func hidden(_ id: Note.ID) -> Bool { privacy.hides(.notes, "note.\(id)") }

    private var selectedHidden: Bool {
        guard let id = notes.selected else { return false }
        return hidden(id)
    }

    var body: some View {
        HStack(spacing: 10) {
            list
            editor
        }
        .padding(.top, 2)
        // Arriving means arriving to type. With nothing to select, an empty
        // note is created on the spot: a welcome screen with a button would be
        // slower than the editor window this tab exists to replace.
        .onAppear {
            if notes.notes.isEmpty {
                notes.add()
                // Same deal as the + button below: a note born under the caret
                // is being written by the one person looking at it. Covered,
                // it would arrive with the editor disabled — a focused field
                // that eats no keys, on the tab that exists to be typed into.
                if let id = notes.selected { privacy.reveal("note.\(id)") }
            } else if notes.selected == nil {
                notes.selected = notes.notes.first?.id
            }
        }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
    }

    /// What lies over the editor while the chosen note is covered. The editor
    /// itself stays where it is underneath — see the note at the editor.
    private var editorCover: some View {
        ZStack {
            SpoilerField(seed: seed(for: notes.selected))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let id = notes.selected {
                Button { privacy.reveal("note.\(id)") } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .help(localized("Show"))
            }
        }
    }

    private func seed(for id: Note.ID?) -> UInt64 {
        guard let id else { return 0x9E3779B97F4A7C05 }
        return UInt64(bitPattern: Int64(id.hashValue))
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 3) {
            Button {
                notes.add()
                // A note created by hand is uncovered from the start: it is
                // being written this second, by the person looking at it, and
                // asking them to uncover their own blank page before typing
                // into it would be a riddle, not a precaution.
                if let id = notes.selected { privacy.reveal("note.\(id)") }
                focused = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New Note")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.surface)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(notes.notes) { note in
                        NoteRow(
                            note: note,
                            isSelected: notes.selected == note.id,
                            hidden: hidden(note.id),
                            showsEye: privacy.covers(.notes),
                            toggleReveal: { privacy.toggle("note.\(note.id)") },
                            select: {
                                notes.selected = note.id
                                focused = true
                            },
                            delete: {
                                notes.remove(note.id)
                                // The tab's invariant: there is always a note
                                // under the caret.
                                if notes.notes.isEmpty { notes.add() }
                            }
                        )
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .frame(width: 170)
    }

    // MARK: - Editor

    private var currentText: String {
        guard let id = notes.selected else { return "" }
        return notes.notes.first(where: { $0.id == id })?.text ?? ""
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { currentText },
            set: { text in
                guard let id = notes.selected else { return }
                notes.update(id, text: text)
            }
        )
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: editorBinding)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .focused($focused)
                // The editor insets its text by a few points of its own; pull
                // that back so the first character lines up with the padding.
                .padding(.leading, -5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // One editor for all notes, deliberately NOT remounted per
                // note. A remount (`.id(selected)`) tears the focused view
                // down, and SwiftUI's cleanup for "the focused view
                // disappeared" clears the FocusState at a moment of its own
                // choosing — racing, and regularly beating, every way of
                // re-requesting focus: a plain set, a deferred set, even
                // `defaultFocus`. All three were tried; the new note kept
                // arriving without a caret. With one long-lived editor the
                // text swaps inside a view that never dies, so there is no
                // cleanup and nothing to race. AppKit clamps the caret to the
                // new text's length — for a fresh note that is position zero,
                // exactly where it belongs.
                //
                // A shared undo stack looked like the price of this, but
                // measurement says otherwise: ⌘Z undoes typing fine within a
                // note, and after switching notes the old actions are simply
                // inert — deleted text does not resurface in the neighbour,
                // in either note, on any press. The programmatic text swap
                // leaves the stale actions unable to apply. Verified by
                // driving the real app: type, delete, switch, ⌘Z twice,
                // read the store after each step.
                //
                // Asked in onAppear because on arrival at the tab the request
                // must come from a view that exists (see SnippetsPane).
                .onAppear {
                    DispatchQueue.main.async { focused = wantsKeyboard }
                }
                .onKeyPress(.escape) {
                    // Esc hands the keyboard back, and only that. It never
                    // clears: this pane holds the one kind of text that cannot
                    // be re-derived from anywhere.
                    wantsKeyboard = false
                    return .handled
                }

            if currentText.isEmpty {
                Text("Jot something down…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiary)
                    .allowsHitTesting(false)
            }
        }
        // Covered, the editor is faded out and switched off rather than taken
        // out of the view tree. Removing it is what the long note above warns
        // against: the editor is deliberately mounted once for the whole pane,
        // and tearing down a focused text view hands SwiftUI's focus cleanup a
        // chance to fire after the next request. Alpha zero draws no glyphs —
        // there is nothing composited to recover — and `disabled` makes sure a
        // keystroke cannot land in something nobody can read.
        .opacity(selectedHidden ? 0 : 1)
        .disabled(selectedHidden)
        .overlay {
            if selectedHidden { editorCover }
        }
        // Above the curtain on purpose: a covered note still copies, the same
        // way a covered row in the other tabs does. Using what is hidden must
        // not require showing it first.
        .overlay(alignment: .topTrailing) {
            if !currentText.isEmpty {
                CopyNoteButton(text: currentText)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }
}

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let hidden: Bool
    let showsEye: Bool
    let toggleReveal: () -> Void
    let select: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    /// Shown in place of the first line while the note is covered. A note has
    /// no name of its own — the list borrows its opening words, which is the
    /// text itself — so the time it was last touched stands in: enough to tell
    /// two notes apart and to recognise the one just written, and it says
    /// nothing about what is in them.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            if hidden {
                Text(Self.clock.string(from: note.edited))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.secondary : Theme.tertiary)
                    // The dust beside it asks for every point of the row and
                    // asks with a higher layout priority, so without this the
                    // time is squeezed to nothing — which is the whole reason
                    // it is there. Verified by looking: the covered rows came
                    // out with a blank margin where the time should have been.
                    .fixedSize()
                SpoilerText(
                    text: preview,
                    hidden: true,
                    height: 11,
                    seed: UInt64(bitPattern: Int64(note.id.hashValue))
                )
            } else {
                Text(preview)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hovering, showsEye {
                RevealEye(hidden: hidden, action: toggleReveal)
            }
            if hovering {
                Button(action: delete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .help(localized("Delete"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.surfaceHover : hovering ? Theme.surface : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }

    /// The first line stands in for a title — notes here are too short-lived
    /// to deserve naming as a separate step.
    private var preview: String {
        let line = note.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        return line.isEmpty ? localized("Empty note") : line
    }
}

private struct CopyNoteButton: View {
    let text: String

    var body: some View {
        CopyButton {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
