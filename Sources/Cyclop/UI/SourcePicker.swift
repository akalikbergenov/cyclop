import AppKit
import SwiftUI

/// The source name in the music tab's header, which is also the way to pick
/// one: it lights up under the pointer, and a click opens the list.
struct SourceName: View {
    @ObservedObject var media: MediaController
    @Binding var isExpanded: Bool

    @State private var hovered = false

    /// Nothing to choose between and nothing chosen: plain text, as before.
    private var isInteractive: Bool { !media.sources.isEmpty || media.chosenSource != nil }

    var body: some View {
        HStack(spacing: 6) {
            if media.track != nil {
                EqualizerBars(isAnimating: media.isPlaying)
            }
            Text(media.sourceName ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovered || isExpanded ? Color.white.opacity(0.85) : Theme.tertiary)
                .shadow(color: .white.opacity(hovered || isExpanded ? 0.35 : 0), radius: 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(hovered || isExpanded ? Theme.surface : .clear)
        )
        .contentShape(Capsule())
        .onHover { hovered = isInteractive && $0 }
        .onTapGesture {
            guard isInteractive else { return }
            isExpanded.toggle()
        }
        .animation(Theme.contentAnimation, value: hovered)
        .animation(Theme.contentAnimation, value: isExpanded)
    }
}

/// The list itself: automatic first, then every app with a track, and the
/// chosen app even while it has none, so the tick always has a row to sit on.
struct SourceList: View {
    @ObservedObject var media: MediaController
    @Binding var isExpanded: Bool

    private struct Row: Identifiable {
        let id: String
        let bundleID: String?
        let name: String
        let isPlaying: Bool
        let isAvailable: Bool
    }

    private var rows: [Row] {
        var rows = [Row(id: "auto", bundleID: nil, name: localized("Automatically"), isPlaying: false, isAvailable: true)]
        rows += media.sources.map {
            Row(id: $0.bundleID, bundleID: $0.bundleID, name: $0.name, isPlaying: $0.isPlaying, isAvailable: true)
        }
        if let chosen = media.chosenSource, !media.sources.contains(where: { $0.bundleID == chosen }) {
            rows.append(Row(id: chosen, bundleID: chosen, name: Self.appName(chosen), isPlaying: false, isAvailable: false))
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows) { row in
                SourceRow(
                    name: row.name,
                    isPlaying: row.isPlaying,
                    isChosen: media.chosenSource == row.bundleID,
                    isAvailable: row.isAvailable
                ) {
                    media.choose(row.bundleID)
                    isExpanded = false
                }
            }
        }
        .padding(4)
        .frame(width: 190)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.11))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

private struct SourceRow: View {
    let name: String
    let isPlaying: Bool
    let isChosen: Bool
    let isAvailable: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(isChosen ? 1 : 0)
                    .frame(width: 10)
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isAvailable ? Color.white : Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isPlaying {
                    EqualizerBars(isAnimating: true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered ? Theme.surfaceHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
