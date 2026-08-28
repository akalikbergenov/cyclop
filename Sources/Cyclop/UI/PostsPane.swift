import SwiftUI

struct PostsPane: View {
    @ObservedObject var posts: PostStore

    var body: some View {
        VStack(spacing: 0) {
            if posts.items.isEmpty {
                Image(systemName: "bookmark")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(posts.filtered) { post in
                            PostRow(post: post, posts: posts)
                        }
                    }
                    .padding(.vertical, 4)
                }
                footer
            }
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Clear") { posts.clear() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 2)
    }
}

private struct PostRow: View {
    let post: SavedPost
    @ObservedObject var posts: PostStore
    @State private var hovering = false

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
            Text(post.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            if !post.note.isEmpty {
                Text(post.note.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovering {
                CopyButton { posts.copy(post) }
                Button { posts.remove(post) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
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
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // The row is the post: clicking it opens the browser, and the browser
        // arriving is its own confirmation — no flash needed.
        .onTapGesture { posts.open(post) }
        .animation(Theme.contentAnimation, value: hovering)
    }

    /// "5 min. ago" in whatever language the panel speaks, for free.
    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
