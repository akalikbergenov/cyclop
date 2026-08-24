import SwiftUI

struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode

    var body: some View {
        VStack(spacing: 0) {
            if clipboard.items.isEmpty {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(clipboard.items) { item in
                            ClipRow(item: item, clipboard: clipboard, privacy: privacy)
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
            PrivacySwitch(privacy: privacy, section: .clipboard)
            Button("Clear") { clipboard.clear() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 2)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    @State private var hovering = false
    @State private var justCopied = false

    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            SpoilerText(
                text: item.preview.replacingOccurrences(of: "\n", with: " "),
                hidden: hidden,
                seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue))
            )
            Spacer(minLength: 6)
            if hovering {
                if privacy.covers(.clipboard) {
                    RevealEye(hidden: hidden) { privacy.toggle(item.id.uuidString) }
                }
                Button { clipboard.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
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
            clipboard.copy(item)
            flash($justCopied)
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }
}
