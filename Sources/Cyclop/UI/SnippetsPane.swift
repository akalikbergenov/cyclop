import SwiftUI

struct SnippetsPane: View {
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard, so the fields can follow it.
    @Binding var wantsKeyboard: Bool

    /// Which field has the caret. One state for all three, because only one of
    /// them can be typed into at a time and the pane switches between them.
    private enum Field { case search, group, label, text }

    @FocusState private var focused: Field?
    @State private var isAdding = false
    @State private var draftLabel = ""
    @State private var draftText = ""
    /// Set while the form is making a group rather than a plain snippet: the
    /// group needs a name of its own, above the first row's.
    @State private var draftGroup: String?

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
            }
            Button { beginAdding(group: true) } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Add a group"))

            Button { beginAdding() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
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
            if draftGroup != nil {
                TextField(
                    localized("Group"),
                    text: Binding(get: { draftGroup ?? "" }, set: { draftGroup = $0 })
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .padding(.horizontal, 7)
                .frame(width: 92, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surface)
                )
                .focused($focused, equals: .group)
                .onSubmit { commit() }
            }
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
            .disabled(draftText.isEmpty)

            Button { cancelAdding() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
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
        .onAppear { focused = draftGroup == nil ? .text : .group }
        // Escape leaves the draft rather than the tab. Caught on the row so it
        // works from either field.
        .onKeyPress(.escape) {
            cancelAdding()
            return .handled
        }
    }

    private func beginAdding(group: Bool = false) {
        draftGroup = group ? "" : nil
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
        draftGroup = nil
        draftLabel = ""
        draftText = ""
    }

    private func commit() {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let name = draftGroup {
            // A group is made with its first row and then closes the form: the
            // rest is added from the group's own plus, where the name is
            // already decided and does not need retyping.
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            snippets.addGroup(label: name, itemLabel: draftLabel, itemText: draftText)
            cancelAdding()
            return
        }
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
                        if item.isGroup {
                            SnippetGroup(
                                group: item,
                                snippets: snippets,
                                privacy: privacy,
                                wantsKeyboard: $wantsKeyboard
                            )
                        } else {
                            SnippetRow(
                                item: item,
                                snippets: snippets,
                                privacy: privacy,
                                wantsKeyboard: $wantsKeyboard
                            )
                        }
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
    /// The group this row belongs to, if it is inside one. Every edit goes
    /// through it, so the row itself does not have to know two sets of methods.
    var group: Snippet?
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

    private var key: String { "snippet.\(group.map { "\($0.id)/" } ?? "")\(item.id)" }
    private var hidden: Bool { privacy.hides(.snippets, key) && !editing }
    /// Position in the stored list, not in the filtered one: moving is an edit
    /// of the file's order, and the filter is only a way of looking at it.
    /// A row on its own sits on a lit surface against the black panel. A row
    /// inside a group sits on that same surface, so lighting it again would
    /// make two barely different greys — the group and its contents blurred
    /// into one patch. Inside, the rows are sunk instead.
    private var fill: Color {
        guard group != nil else {
            return editing || hovering ? Theme.surfaceHover : Theme.surface
        }
        return editing || hovering ? Color.black.opacity(0.18) : Color.black.opacity(0.32)
    }

    private var siblings: [Snippet] { group?.items ?? snippets.items }
    private var index: Int { siblings.firstIndex(where: { $0.id == item.id }) ?? 0 }
    private var isLast: Bool { index >= siblings.count - 1 }

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
                    RevealEye(hidden: hidden) { privacy.toggle(key) }
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
                .help(localized("Delete"))
            }
        }
        .padding(.horizontal, editing ? 6 : 9)
        .frame(height: editing ? 28 : 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
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
        if let group {
            snippets.move(item, to: index, in: group)
        } else {
            snippets.move(item, to: index)
        }
    }

    private func remove() {
        if let group {
            snippets.remove(item, from: group)
        } else {
            snippets.remove(item)
        }
    }

    private func cancel() {
        editing = false
        focus = nil
    }

    private func commit() {
        guard editing else { return }
        editing = false
        focus = nil
        if let group {
            snippets.update(item, in: group, label: draftLabel, text: draftText)
        } else {
            snippets.update(item, label: draftLabel, text: draftText)
        }
    }
}

/// A group: one name with several values under it, all of them on view.
///
/// Not a folder that opens. The pair this exists for is a login and its
/// password, and hiding one behind a click would undo the point of keeping them
/// together. Only past a few rows does it fold, and then to keep the panel —
/// five rows tall — from being spent on a single group.
private struct SnippetGroup: View {
    let group: Snippet
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var privacy: PrivacyMode
    @Binding var wantsKeyboard: Bool

    @State private var hovering = false
    @State private var collapsed = false
    @State private var adding = false
    @State private var draftLabel = ""
    @State private var draftText = ""
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var focus: Field?

    private enum Field { case name, label, text }

    /// Rows are folded away only when there are enough of them to be worth it.
    private static let foldsPast = 3

    private var rows: [Snippet] { group.items ?? [] }
    private var foldable: Bool { rows.count > Self.foldsPast }
    private var index: Int { snippets.items.firstIndex(where: { $0.id == group.id }) ?? 0 }
    private var isLast: Bool { index >= snippets.items.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !collapsed {
                ForEach(rows) { row in
                    SnippetRow(
                        item: row,
                        group: group,
                        snippets: snippets,
                        privacy: privacy,
                        wantsKeyboard: $wantsKeyboard
                    )
                }
                if adding { draft }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: collapsed)
        .animation(Theme.contentAnimation, value: adding)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if foldable {
                Button { collapsed.toggle() } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }

            if renaming {
                TextField(localized("Name"), text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .tint(Theme.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .focused($focus, equals: .name)
                    .onSubmit { commitRename() }
            } else {
                // The name stays readable whatever is covered below it: a list
                // of covered groups must still say which is which.
                Text(group.label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }

            if collapsed {
                Text("\(rows.count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer(minLength: 4)

            if hovering, !renaming {
                Button { beginAdding() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Add a snippet"))

                Button { snippets.move(group, to: index - 1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(index == 0 ? Theme.tertiary : Theme.secondary)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button { snippets.move(group, to: index + 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isLast ? Theme.tertiary : Theme.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isLast)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 16)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRenaming() }
    }

    /// The same pair of fields as everywhere else, so adding to a group looks
    /// like adding anywhere.
    private var draft: some View {
        HStack(spacing: 6) {
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
                .onSubmit { commitAdding() }

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
                .onSubmit { commitAdding() }

            Button { commitAdding() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(draftText.isEmpty ? Theme.tertiary : Color.green)
            }
            .buttonStyle(.plain)
            .disabled(draftText.isEmpty)

            Button { cancelAdding() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surfaceHover)
        )
        .onExitCommand { cancelAdding() }
    }

    private func beginAdding() {
        draftLabel = ""
        draftText = ""
        collapsed = false
        adding = true
        wantsKeyboard = true
        focus = .text
    }

    private func commitAdding() {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        snippets.addToGroup(group, label: draftLabel, text: draftText)
        cancelAdding()
    }

    private func cancelAdding() {
        adding = false
        draftLabel = ""
        draftText = ""
        focus = nil
    }

    private func beginRenaming() {
        draftName = group.label
        renaming = true
        wantsKeyboard = true
        focus = .name
    }

    private func commitRename() {
        renaming = false
        focus = nil
        snippets.rename(group, to: draftName)
    }
}
