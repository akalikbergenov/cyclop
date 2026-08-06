import SwiftUI

struct MediaPane: View {
    @ObservedObject var media: MediaController

    @State private var scrubHover = false
    /// Set while dragging, so the bar follows the finger instead of the clock.
    @State private var scrubbing: Double?
    /// The transport row yields to the volume slider while this is set —
    /// hovering the speaker opens it, leaving the row closes it. One row,
    /// two duties, never both at once.
    @State private var volumeExpanded = false
    /// Total ↔ remaining on the right-hand timer; survives restarts because a
    /// preference this small should not need re-teaching.
    @AppStorage("mediaShowRemaining") private var showRemaining = false

    /// Artwork and the text column share this height, so their top and bottom
    /// edges line up instead of the column floating past them.
    private let blockHeight: CGFloat = 122

    var body: some View {
        if let track = media.track {
            HStack(spacing: 18) {
                artwork(for: track)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle(for: track))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.top, 3)

                    Spacer(minLength: 6)
                    controls
                    Spacer(minLength: 6)
                    scrubber
                }
                .frame(height: blockHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Title and artist arrive together, so the whole column can cross-
            // fade as one unit when the track changes.
            .animation(Theme.artworkAnimation, value: track.key)
        } else {
            emptyState
        }
    }

    /// The system often repeats the title as the album name; showing
    /// "Artist — Title" twice reads like a bug.
    private func subtitle(for track: MediaController.Track) -> String {
        var parts = [track.artist]
        if !track.album.isEmpty, track.album != track.title { parts.append(track.album) }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    // MARK: - Artwork

    private func artwork(for track: MediaController.Track) -> some View {
        ZStack {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if media.artworkUnavailable {
                // No cover exists anywhere for this track (Spotify local files,
                // mostly). A skeleton here would shimmer forever and read as a
                // bug; a quiet glyph reads as the truth.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Theme.tertiary)
                    )
                    .transition(.opacity)
            } else {
                SkeletonBox(cornerRadius: 14)
            }
        }
        .frame(width: 118, height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        .animation(Theme.artworkAnimation, value: media.artwork)
        // The cover is the door to the app that is playing.
        .onTapGesture { media.openPlayer() }
    }

    // MARK: - Scrubber

    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(formatTime(progress * media.duration))
                .frame(width: 32, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                let filled = width * progress
                let height: CGFloat = scrubHover ? 6 : 4

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface).frame(height: height)
                    // Deliberately unanimated: a seek has to land under the
                    // cursor at once. Smoothness comes from the tick rate
                    // instead, which keeps each step well under a pixel.
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: filled, height: height)
                    if scrubHover {
                        Circle()
                            .fill(.white)
                            .frame(width: 11, height: 11)
                            .offset(x: min(max(filled - 5.5, 0), width - 11))
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { scrubHover = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            scrubbing = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard width > 0 else { return }
                            let target = min(max(value.location.x / width, 0), 1)
                            // Seek first: clearing `scrubbing` beforehand would
                            // drop the bar back to the old position for a frame
                            // before the new one lands.
                            media.seek(to: media.duration * target)
                            scrubbing = nil
                        }
                )
                .animation(Theme.contentAnimation, value: scrubHover)
            }
            .frame(height: 14)

            // Total by default, remaining on click — the countdown DJs watch.
            Text(showRemaining
                 ? "-" + formatTime(max(0, media.duration - progress * media.duration))
                 : formatTime(media.duration))
                .frame(width: 36, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { showRemaining.toggle() }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.tertiary)
    }

    // MARK: - Transport

    private var controls: some View {
        ZStack {
            if volumeExpanded, media.volume != nil {
                expandedVolume.transition(.opacity)
            } else {
                transportRow.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        // The container spans both faces of the row, so leaving it always
        // folds the slider back — including the case where the swap happened
        // under a cursor that then left without ever touching the slider.
        .onHover { inside in if !inside { volumeExpanded = false } }
        .animation(Theme.contentAnimation, value: volumeExpanded)
    }

    private var transportRow: some View {
        HStack(spacing: 16) {
            if media.shuffle != nil {
                modeToggle("shuffle", active: media.shuffle == true) { media.toggleShuffle() }
            }
            Button { media.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(NotchButtonStyle(size: 30))
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 40, prominent: true))
            Button { media.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(NotchButtonStyle(size: 30))
            if let mode = media.repeatMode {
                modeToggle(mode == .one ? "repeat.1" : "repeat", active: mode != .off) {
                    media.cycleRepeat()
                }
            }
            if media.volume != nil {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { volumeExpanded = true } }
            }
        }
    }

    /// Shuffle and repeat: quieter than transport, lit when engaged.
    private func modeToggle(_ system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? .white : Theme.tertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Volume

    /// What the transport row becomes while the speaker is hovered: one wide
    /// slider with the level spelled out, gone the moment the cursor leaves.
    private var expandedVolume: some View {
        HStack(spacing: 10) {
            Image(systemName: volumeIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24)

            GeometryReader { geo in
                let width = geo.size.width
                let level = Double(media.volume ?? 0) / 100
                let filled = width * level

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface).frame(height: 5)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: filled, height: 5)
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .offset(x: min(max(filled - 5.5, 0), max(width - 11, 0)))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            media.setVolume(Int(min(max(value.location.x / width, 0), 1) * 100))
                        }
                )
            }
            .frame(height: 24)

            Text("\(media.volume ?? 0)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 4)
    }

    private var volumeIcon: String {
        switch media.volume ?? 0 {
        case 0: return "speaker.slash.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            // Status, not instruction: an empty pane on its own would not say
            // whether nothing is playing or nothing could be read.
            Text("Nothing is playing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
