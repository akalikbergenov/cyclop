import SwiftUI

struct SnippetsPane: View {
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard, so the fields can follow it.
    @Binding var wantsKeyboard: Bool

    /// Which field has the caret. One state for all three, because only one of
    /// them can be typed into at a time and the pane switches between them.
    private enum Field { case search, label, text }

    @FocusState private var focused: Field?
    @State private var isAdding = false
    @State private var draftLabel = ""
    @State private var draftText = ""

    var body: some View {
        VStack(spacing: 6) {
            if isAdding { editor } else { search }
            if snippets.fileBroken { brokenNotice }
            list
        }
        .padding(.top, 2)
        .onChange(of: wantsKeyboard) { _, wants in
            guard !wants else {
                focused = isAdding ? .text : .search
                return
            }
            focused = nil
        }
        .animation(Theme.contentAnimation, value: isAdding)
    }

    // MARK: - Search

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField("", text: $snippets.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .focused($focused, equals: .search)
                .onKeyPress(.escape) {
                    snippets.query = ""
                    return .handled
                }
            if !snippets.query.isEmpty {
                Button { snippets.query = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
            }
            Button { beginAdding() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .help(localized("Add a snippet"))
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = .search }
        // Same reason as the editor: the row asks for the caret once it is
        // actually on screen, so arriving on the tab and coming back from the
        // editor both land the same way.
        .onAppear { if wantsKeyboard { focused = .search } }
    }

    /// The refusal to write over a broken file (#7) is only honest if it is
    /// said out loud: a log line is where refusals go to be unread.
    private var brokenNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.yellow.opacity(0.85))
            Text("snippets.json is broken — click to open; nothing is overwritten")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { SnippetStore.reveal() }
    }

    // MARK: - Adding

    /// Takes the place of the search row rather than sitting above it: the pane
    /// is two rows tall in a panel that never resizes, and one of the two is
    /// the list.
    private var editor: some View {
        HStack(spacing: 6) {
            // Each field on its own surface. A hairline between them read as a
            // caret sitting in the wrong place — exactly where one is expected,
            // which is the worst place for something that only looks like one.
            TextField(localized("Name"), text: $draftLabel)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .padding(.horizontal, 7)
                .frame(width: 104, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surface)
                )
                .focused($focused, equals: .label)
                .onSubmit { commit() }

            TextField(localized("Text"), text: $draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surface)
                )
                .focused($focused, equals: .text)
                .onSubmit { commit() }

            Button { commit() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(draftText.isEmpty ? Theme.tertiary : Color.green)
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .disabled(draftText.isEmpty)

            Button { cancelAdding() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surfaceHover)
        )
        // Asked for here rather than where the editor is switched on: at that
        // moment this field does not exist yet, and a focus request aimed at a
        // view that is not in the hierarchy is simply dropped. The row would
        // appear with no caret in it, and nothing to type into until clicked.
        //
        // The value is the part that cannot be left out, so the caret starts
        // there; the name is a step back for those who want one.
        .onAppear { focused = .text }
        // Escape leaves the draft rather than the tab. Caught on the row so it
        // works from either field.
        .onKeyPress(.escape) {
            cancelAdding()
            return .handled
        }
    }

    private func beginAdding() {
        draftLabel = ""
        draftText = ""
        // The search field goes away with the row, but the filter behind it
        // would not: a snippet added under a live filter lands in the list and
        // is hidden by it in the same breath, which looks like it was not added
        // at all.
        snippets.query = ""
        isAdding = true
        wantsKeyboard = true
    }

    private func cancelAdding() {
        isAdding = false
        draftLabel = ""
        draftText = ""
    }

    private func commit() {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        snippets.add(label: draftLabel, text: draftText)
        // Straight into another one: adding snippets comes in runs, and the
        // list underneath already shows what has landed.
        draftLabel = ""
        draftText = ""
        focused = .text
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if snippets.filtered.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: snippets.items.isEmpty ? "pin" : "magnifyingglass")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                if snippets.items.isEmpty, !isAdding {
                    Text("Nothing here yet — add with +")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(snippets.filtered) { item in
                        SnippetRow(
                            item: item,
                            snippets: snippets,
                            privacy: privacy,
                            wantsKeyboard: $wantsKeyboard
                        )
                    }
                }
                .animation(Theme.contentAnimation, value: snippets.items)
                .padding(.bottom, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SnippetRow: View {
    let item: Snippet
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var privacy: PrivacyMode
    /// Editing needs the keyboard, and the panel only takes it when asked.
    @Binding var wantsKeyboard: Bool
    @State private var hovering = false
    @State private var justCopied = false
    /// Set by a double click. While it is on, the row shows two fields instead
    /// of its text, and the value is shown even under cover — editing what one
    /// cannot read is not editing.
    @State private var editing = false
    @State private var draftLabel = ""
    @State private var draftText = ""
    @FocusState private var focus: Field?

    private enum Field { case label, text }

    private var hidden: Bool { privacy.hides(.snippets, "snippet.\(item.id)") && !editing }
    /// Position in the stored list, not in the filtered one: moving is an edit
    /// of the file's order, and the filter is only a way of looking at it.
    private var index: Int { snippets.items.firstIndex(where: { $0.id == item.id }) ?? 0 }
    private var isLast: Bool { index >= snippets.items.count - 1 }

    var body: some View {
        HStack(spacing: editing ? 6 : 9) {
            if !editing {
                Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                    .frame(width: 14)
            }
            // The name stays legible while the value is covered: the row has to
            // say what it copies, or a list of covered rows is a list of
            // identical rows. An unnamed snippet shows its value as its name,
            // so covering the value covers the whole row — which is right,
            // since there is nothing else in it.
            if editing {
                // The same two surfaces as the add form above: a row being
                // edited and a row being created are the same act, and looking
                // alike is the whole of saying so. Bare fields inside the row
                // read as text that had lost its alignment.
                TextField(localized("Name"), text: $draftLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .tint(Theme.secondary)
                    .padding(.horizontal, 7)
                    .frame(width: 104, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .focused($focus, equals: .label)
                    .onSubmit { commit() }

                TextField(localized("Text"), text: $draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .tint(Theme.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .focused($focus, equals: .text)
                    .onSubmit { commit() }

                Button { commit() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(draftText.isEmpty ? Theme.tertiary : Color.green)
                }
                .buttonStyle(.plain)
                .disabled(draftText.isEmpty)

                Button { cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            } else {
                if !item.label.isEmpty {
                    Text(item.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                SpoilerText(
                    text: item.text.replacingOccurrences(of: "\n", with: " "),
                    hidden: hidden,
                    color: item.label.isEmpty ? .white : Theme.secondary,
                    seed: UInt64(bitPattern: Int64(item.id.hashValue))
                )
            }
            Spacer(minLength: 6)
            // Only under the pointer: a row of crosses would compete with the
            // snippets themselves for a glance.
            if hovering, !editing {
                if privacy.covers(.snippets) {
                    RevealEye(hidden: hidden) { privacy.toggle("snippet.\(item.id)") }
                }
                // Order is priority: the one reached for most often belongs on
                // top. Arrows rather than dragging — the list is a few rows
                // long, and a drag here brought more edge cases than movement:
                // where a row lands under a live filter, what happens past the
                // ends, and how it coexists with the taps that copy and edit.
                Button { move(to: index - 1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(index == 0 ? Theme.tertiary : Theme.secondary)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button { move(to: index + 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isLast ? Theme.tertiary : Theme.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isLast)

                Button { remove() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .help(localized("Delete"))
            }
        }
        .padding(.horizontal, editing ? 6 : 9)
        .frame(height: editing ? 28 : 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(editing || hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Double first: SwiftUI hands a tap to the last matching gesture, and
        // with the single one declared first a double click would only ever
        // copy. The first click of a double still copies — harmless, and the
        // alternative is delaying every single click to see if a second lands.
        .onTapGesture(count: 2) { beginEditing() }
        .onTapGesture {
            snippets.copy(item)
            // Emptying the search lets go of the panel: nothing is being typed
            // any more, so nothing needs to hold it open.
            snippets.query = ""
            flash($justCopied)
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
        .animation(Theme.contentAnimation, value: editing)
        .onExitCommand { cancel() }
        // Losing the focus saves: clicking away from a row one has just edited
        // is not a way of throwing the edit out — Esc is.
        .onChange(of: focus) { _, now in
            if editing, now == nil { commit() }
        }
        // The panel folds by itself when the pointer leaves, and the row goes
        // with it. Whatever was typed by then has to survive that.
        .onDisappear { if editing { commit() } }
    }

    private func beginEditing() {
        draftLabel = item.label
        draftText = item.text
        editing = true
        focus = item.label.isEmpty ? .text : .label
        wantsKeyboard = true
    }

    private func move(to index: Int) {
        snippets.move(item, to: index)
    }

    private func remove() {
        snippets.remove(item)
    }

    private func cancel() {
        editing = false
        focus = nil
    }

    private func commit() {
        guard editing else { return }
        editing = false
        focus = nil
        snippets.update(item, label: draftLabel, text: draftText)
    }
}
