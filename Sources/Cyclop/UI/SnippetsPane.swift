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
            }
            PrivacySwitch(privacy: privacy, section: .snippets)
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
                        SnippetRow(item: item, snippets: snippets, privacy: privacy)
                    }
                }
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
    @State private var hovering = false
    @State private var justCopied = false

    private var hidden: Bool { privacy.hides(.snippets, "snippet.\(item.id)") }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            // The name stays legible while the value is covered: the row has to
            // say what it copies, or a list of covered rows is a list of
            // identical rows. An unnamed snippet shows its value as its name,
            // so covering the value covers the whole row — which is right,
            // since there is nothing else in it.
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
            Spacer(minLength: 6)
            // Only under the pointer: a row of crosses would compete with the
            // snippets themselves for a glance.
            if hovering {
                if privacy.covers(.snippets) {
                    RevealEye(hidden: hidden) { privacy.toggle("snippet.\(item.id)") }
                }
                Button { snippets.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Delete"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            snippets.copy(item)
            // Emptying the search lets go of the panel: nothing is being typed
            // any more, so nothing needs to hold it open.
            snippets.query = ""
            flash($justCopied)
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }
}
