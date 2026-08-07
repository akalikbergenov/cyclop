import SwiftUI

/// What the keyboard-driven clipboard list shows, and which row is armed.
///
/// Separate from `BufferStore`: the store is the history, this is one
/// pass through it. The snapshot is taken when the picker opens and is not
/// re-taken while it is up — a copy landing in another app mid-choice would
/// otherwise shuffle the rows under a selection the user is aiming with.
@MainActor
final class BufferPickerModel: ObservableObject {
    @Published private(set) var items: [BufferItem] = []
    @Published var selection = 0
    /// Raised when the entry was put on the pasteboard but could not be typed
    /// in, because the app has not been granted Accessibility yet.
    @Published var needsAccessibility = false

    /// How many rows are on screen at once. Also the step ⇞ / ⇟ take.
    static let visibleRows = 8

    func load(_ items: [BufferItem]) {
        self.items = items
        selection = items.isEmpty ? 0 : 0
        needsAccessibility = false
    }

    var selected: BufferItem? {
        guard items.indices.contains(selection) else { return nil }
        return items[selection]
    }

    /// Wraps at both ends: with eight rows on screen and forty in history, the
    /// last entry is one ↑ away instead of thirty-nine ↓.
    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selection = ((selection + delta) % count + count) % count
    }

    func moveToStart() { selection = 0 }
    func moveToEnd() { selection = max(items.count - 1, 0) }
}

struct BufferPickerView: View {
    @ObservedObject var model: BufferPickerModel
    @ObservedObject var privacy: PrivacyMode
    /// Clicking a row does what Return does. The mouse is not the point of this
    /// panel, but a list on screen that ignores a click is its own small bug.
    var onChoose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if model.items.isEmpty {
                empty
            } else {
                rows
            }
            Divider().overlay(Theme.hairline)
            footer
        }
        .background(
            ZStack {
                VisualEffectBackground()
                Color.black.opacity(0.28)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "list.clipboard.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text(localized("Buffer"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if !model.items.isEmpty {
                Text("\(model.selection + 1)/\(model.items.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(localized("Buffer is empty"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // Identified by position, not by the entry's own id, and the
                // `.id` below matches. Two identities on one row is one too
                // many: with the rows keyed by entry and the scroll anchor
                // keyed by position, a copy arriving while the list was up
                // re-mapped the entries to new positions and SwiftUI kept the
                // old rendering — rows showing the text of their former
                // neighbours, and the highlight several rows away from the
                // entry the header said was selected. The list is a snapshot
                // that does not change while it is on screen, so position is
                // the honest identity here.
                LazyVStack(spacing: 2) {
                    ForEach(model.items.indices, id: \.self) { index in
                        PickerRow(
                            item: model.items[index],
                            index: index,
                            selected: index == model.selection,
                            // Covered rows stay covered, but never the one the
                            // selection is on: a list nobody can read is a list
                            // nobody can choose from, and the arrow keys are
                            // what uncovers it — one row at a time, which is
                            // the same bargain the eye button strikes in the
                            // panel itself.
                            hidden: privacy.covers(.clipboard) && index != model.selection
                        )
                        .id(index)
                        .onTapGesture { onChoose(index) }
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 5)
            }
            .frame(height: rowsHeight)
            .onChange(of: model.selection) { _, new in
                // Without an animation: held-down ↓ walks the list faster than
                // a scroll animation finishes, and the animations then queue
                // up and the list glides on for a second after the key is let
                // go, past the row that is actually selected.
                proxy.scrollTo(new, anchor: .center)
            }
        }
    }

    /// Sized to whole rows, so a short history gets a short panel and a long
    /// one always cuts off mid-list rather than at a row's waist — the cut is
    /// the only thing telling the user there is more below.
    private var rowsHeight: CGFloat {
        let rows = min(model.items.count, BufferPickerModel.visibleRows)
        return CGFloat(rows) * 34 + 10
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.needsAccessibility {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(localized("Copied. Allow Accessibility to paste automatically."))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            } else {
                hint("↑↓", localized("select"))
                hint("↩", localized("paste"))
                hint("⌫", localized("delete"))
                hint("esc", localized("close"))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.surface)
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
        }
    }
}

private struct PickerRow: View {
    let item: BufferItem
    let index: Int
    let selected: Bool
    let hidden: Bool

    var body: some View {
        HStack(spacing: 9) {
            // The first nine rows carry their number, because ⌘1…⌘9 reach them
            // directly. The rest have none rather than a number that does
            // nothing — a label promising a shortcut that is not there is
            // worse than no label.
            Group {
                if index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? Theme.secondary : Theme.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)

            // A picture is recognised by looking at it, not by reading its
            // file name — half the entries in a buffer full of screenshots are
            // called "Screenshot 2026-08-06 at 21.03.11" and differ in the
            // seconds. The glyph stays for text and for files QuickLook has no
            // preview of.
            Group {
                if let icon = item.icon, item.isFile, !hidden {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selected ? .white : Theme.secondary)
                }
            }
            .frame(width: 24, height: 18)

            SpoilerText(
                text: item.preview.replacingOccurrences(of: "\n", with: " "),
                hidden: hidden,
                font: .system(size: 11, weight: selected ? .medium : .regular),
                color: selected ? .white : Color.white.opacity(0.75),
                seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue))
            )

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.55) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

/// The blur behind the picker. Unlike the notch panel this window does not sit
/// over a black cutout — it stands over the user's own screen, wherever the
/// caret happens to be, and a flat fill there reads as a screenshot pasted on
/// top of the desktop.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
