import SwiftUI

/// The buffer tab: one list of everything copied or dropped in.
///
/// A vertical list rather than the shelf's strip of cards. The two had
/// different shapes because they held different things, and now they hold one
/// thing: a list reads top to bottom in the order copies happened, which is the
/// order anyone looks for them in, and it is the same shape the ⌘⌥V picker
/// uses — so the keyboard and the pointer are looking at the same picture.
///
/// Files keep everything the shelf gave them: a thumbnail, dragging out, a
/// group drag from a ⌘-click selection, opening, revealing in Finder.
struct BufferPane: View {
    @ObservedObject var buffer: BufferStore
    @ObservedObject var privacy: PrivacyMode
    var isTargeted: Bool

    /// Which row the pointer is over — decided by the pane, not by the rows.
    ///
    /// Per-row `onHover` breaks on this list's most repetitive gesture:
    /// deleting entries one after another. Hover events are made of mouse
    /// movement, and when a deleted row's neighbour slides under a pointer that
    /// has not moved, there are no events — the neighbour never learns it is
    /// hovered, its ✕ never appears, and the click meant to delete it does
    /// something else, until a stray wiggle of the mouse fixes everything. So
    /// the pane tracks the pointer and every row's frame itself, and re-decides
    /// on either change: the pointer moving, or the rows moving under it.
    @State private var hoveredID: UUID?
    @State private var hoverPoint: CGPoint?
    @State private var frames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if buffer.items.isEmpty {
                dropHint
            } else {
                list
                footer
            }
        }
        .padding(.top, 2)
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 3) {
                ForEach(buffer.items) { item in
                    BufferRow(
                        item: item,
                        buffer: buffer,
                        privacy: privacy,
                        isHovered: hoveredID == item.id
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: RowFramesKey.self,
                                value: [item.id: geo.frame(in: .named("buffer"))]
                            )
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .coordinateSpace(name: "buffer")
        .onContinuousHover(coordinateSpace: .named("buffer")) { phase in
            switch phase {
            case .active(let point):
                hoverPoint = point
                rehit()
            case .ended:
                hoverPoint = nil
                hoveredID = nil
            }
        }
        .onPreferenceChange(RowFramesKey.self) { new in
            frames = new
            rehit()
        }
        // The drop target is the whole panel, so an empty-looking gap between
        // rows still accepts files; this only says so out loud.
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(isTargeted ? 0.5 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
                .animation(Theme.contentAnimation, value: isTargeted)
        )
    }

    /// The one decision both signals feed: which frame holds the last known
    /// pointer position.
    private func rehit() {
        guard let hoverPoint else { return }
        hoveredID = frames.first(where: { $0.value.contains(hoverPoint) })?.key
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                isTargeted ? Color.white.opacity(0.6) : Theme.hairline,
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isTargeted ? Theme.surface : .clear)
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "list.clipboard")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(isTargeted ? .white : Theme.tertiary)
                    Text(localized("Copy something, or drop files here"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.contentAnimation, value: isTargeted)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !buffer.selection.isEmpty {
                Text(localized("Selected: %d", buffer.selection.count))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                Button("Deselect") { buffer.clearSelection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Clear") { buffer.clear() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 2)
    }
}

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct BufferRow: View {
    let item: BufferItem
    @ObservedObject var buffer: BufferStore
    @ObservedObject var privacy: PrivacyMode
    /// Handed down from the pane, which is the one place that can know it
    /// correctly when rows move under a stationary pointer.
    let isHovered: Bool

    @State private var justCopied = false

    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }
    private var isSelected: Bool { buffer.isSelected(item) }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                SpoilerText(
                    text: item.preview.replacingOccurrences(of: "\n", with: " "),
                    hidden: hidden,
                    seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue))
                )
                sourceLine
            }
            Spacer(minLength: 6)
            if isHovered {
                if privacy.covers(.clipboard) {
                    RevealEye(hidden: hidden) { privacy.toggle(item.id.uuidString) }
                }
                Button { buffer.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        // Tall enough for a picture worth looking at. The list used to be a
        // column of 20-point stamps, which for a buffer full of screenshots
        // told you only that they were screenshots.
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(isSelected ? 0.5 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        // Inset on the trailing side, where the reveal eye and the ✕ live. The
        // handler is a view laid over the whole row — for files an AppKit one,
        // which claims every click in its frame — so without this it swallowed
        // the presses aimed at those buttons and copied the row instead of
        // deleting it.
        .overlay(clickHandling.padding(.trailing, isHovered ? 46 : 0))
        .contextMenu {
            if item.isFile {
                Button("Copy") { copy() }
                Button("Open") { buffer.open(item) }
                Button("Show in Finder") { buffer.reveal(item) }
                Divider()
            }
            Button("Remove") { buffer.remove(item) }
        }
        .animation(Theme.contentAnimation, value: isHovered)
        .animation(Theme.contentAnimation, value: justCopied)
    }

    private static let thumbnailSize = CGSize(width: 46, height: 32)

    /// Files get their preview, text a glyph. The tick that says "copied"
    /// replaces either for a moment — it is the answer to the click, and it has
    /// to land where the eye already is.
    @ViewBuilder
    private var thumbnail: some View {
        let size = Self.thumbnailSize
        if justCopied {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green)
                .frame(width: size.width, height: size.height)
        } else if let icon = item.icon, item.isFile {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                // Covered means covered: a thumbnail is the contents of the
                // entry as surely as its text is, and a screenshot of a bank
                // page gives itself away at any size.
                .opacity(hidden ? 0 : 1)
                .overlay {
                    if hidden {
                        SpoilerField(seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue)))
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(width: size.width, height: size.height)
        }
    }

    /// Where the entry came from, in small type under it — the application's
    /// own icon and its name. Kept quiet: it is what tells two similar entries
    /// apart at a glance, not something to read first.
    @ViewBuilder
    private var sourceLine: some View {
        if let source = item.source {
            HStack(spacing: 4) {
                if let icon = source.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 11, height: 11)
                }
                Text(source.name)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var background: Color {
        if isSelected { return Color.white.opacity(0.18) }
        return isHovered ? Theme.surfaceHover : Theme.surface
    }

    /// Files hand their clicks to an AppKit view, because a drag out of the
    /// panel needs one dragging item per file and SwiftUI's `onDrag` can only
    /// ever express one. Text has nothing to drag anywhere, so it keeps the
    /// cheaper tap gesture.
    @ViewBuilder
    private var clickHandling: some View {
        if item.isFile {
            BufferDragSource(
                urls: { buffer.dragURLs(startingAt: item) },
                onClick: { modifiers in
                    if modifiers.contains(.command) || modifiers.contains(.shift) {
                        buffer.select(item, modifiers: modifiers)
                    } else {
                        copy()
                    }
                },
                onDoubleClick: { buffer.open(item) }
            )
        } else {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { copy() }
        }
    }

    private func copy() {
        buffer.copy(item)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { justCopied = false }
    }
}
