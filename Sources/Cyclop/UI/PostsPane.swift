import SwiftUI

struct PostsPane: View {
    @ObservedObject var posts: PostStore
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard, so the fields can follow it.
    @Binding var wantsKeyboard: Bool

    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 6) {
            search
            if posts.fileBroken { brokenNotice }
            list
        }
        .padding(.top, 2)
        // Only the release is followed here. Claiming the caret on every
        // raise would steal it from a note being edited in a row; arrival on
        // the tab is handled by onAppear, and a click lands its own caret.
        .onChange(of: wantsKeyboard) { _, wants in
            if !wants { searching = false }
        }
    }

    // MARK: - Search

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField("", text: $posts.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .focused($searching)
                .onKeyPress(.escape) {
                    posts.query = ""
                    return .handled
                }
            if !posts.query.isEmpty {
                Button { posts.query = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
            }
            PrivacySwitch(privacy: privacy, section: .posts)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture { searching = true }
        .onAppear { if wantsKeyboard { searching = true } }
    }

    /// The refusal to write over a broken file is only honest if it is said
    /// out loud — same notice, same reason as the snippets.
    private var brokenNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.yellow.opacity(0.85))
            Text("posts.json is broken — click to open; nothing is overwritten")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { PostStore.reveal() }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        let shown = posts.filtered
        if shown.isEmpty {
            Image(systemName: posts.items.isEmpty ? "bookmark" : "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                // Lazy, unlike the clipboard's list: the cap here is 200
                // rows against its 40, and a search keystroke re-evaluates
                // the lot — only the dozen on screen are worth building.
                LazyVStack(spacing: 3) {
                    ForEach(shown) { post in
                        PostRow(post: post, posts: posts, privacy: privacy, wantsKeyboard: $wantsKeyboard)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct PostRow: View {
    let post: SavedPost
    @ObservedObject var posts: PostStore
    @ObservedObject var privacy: PrivacyMode
    /// Editing the note needs the keyboard, and the panel only takes it when asked.
    @Binding var wantsKeyboard: Bool
    @State private var hovering = false
    /// Set by a double click. While it is on, the row shows the note field —
    /// shown even under cover, because editing what one cannot read is not
    /// editing.
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var hidden: Bool { privacy.hides(.posts, "post.\(post.id)") && !editing }

    var body: some View {
        HStack(spacing: 9) {
            // The dot is the unread mark; opening the post takes it away.
            Group {
                if post.isRead {
                    Image(systemName: "bookmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 14)
            // One field of dust for the whole row: the author and the note are
            // covered together — who is saved is as telling as what was said
            // about them — and two separate fields would split the row into
            // two puddles.
            if hidden {
                SpoilerText(
                    text: "",
                    hidden: true,
                    seed: UInt64(bitPattern: Int64(post.id.hashValue))
                )
            } else {
                Text(post.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if editing {
                TextField(localized("Note"), text: $draft)
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
                    .focused($focused)
                    .onSubmit { commit() }
            } else if !post.note.isEmpty, !hidden {
                Text(post.note.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if editing {
                Button { commit() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
                .buttonStyle(.plain)
            } else if hovering {
                if privacy.covers(.posts) {
                    RevealEye(hidden: hidden) { privacy.toggle("post.\(post.id)") }
                }
                CopyButton { posts.copy(post) }
                Button { posts.remove(post) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .help(localized("Delete"))
            } else {
                Text(Self.age.localizedString(for: post.savedAt, relativeTo: Date()))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering || editing ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Double first, for the reason stated on the snippet row: declared the
        // other way round, a double click would only ever open.
        .onTapGesture(count: 2) { if !editing { beginEditing() } }
        // The row is the post: clicking it opens the browser, and the browser
        // arriving is its own confirmation — no flash needed. Not while the
        // row is a text field with margins, and not while it is covered: the
        // browser would show exactly what the dust is hiding.
        .onTapGesture {
            guard !editing, !hidden else { return }
            posts.open(post)
        }
        .contextMenu {
            Button(localized("Open")) { posts.open(post) }
            Button(localized("Copy")) { posts.copy(post) }
            Button(post.isRead ? localized("Mark as Unread") : localized("Mark as Read")) {
                posts.setRead(post, !post.isRead)
            }
            Button(post.note.isEmpty ? localized("Add Note") : localized("Edit Note")) { beginEditing() }
            Divider()
            Button(localized("Delete")) { posts.remove(post) }
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: editing)
        .onExitCommand { cancel() }
        // Losing the focus saves: clicking away from a note one has just
        // edited is not a way of throwing the edit out — Esc is.
        .onChange(of: focused) { _, now in
            if editing, !now { commit() }
        }
        // The panel folds by itself when the pointer leaves, and the row goes
        // with it. Whatever was typed by then has to survive that.
        .onDisappear { if editing { commit() } }
    }

    private func beginEditing() {
        draft = post.note
        editing = true
        focused = true
        wantsKeyboard = true
    }

    private func cancel() {
        editing = false
        focused = false
    }

    private func commit() {
        guard editing else { return }
        editing = false
        focused = false
        posts.setNote(post, draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "5 min. ago" in whatever language the panel speaks, for free.
    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
