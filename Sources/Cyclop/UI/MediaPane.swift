import SwiftUI

struct MediaPane: View {
    @ObservedObject var media: MediaController

    @State private var scrubHover = false
    /// Set while dragging, so the bar follows the finger instead of the clock.
    @State private var scrubbing: Double?

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

            Text(formatTime(media.duration))
                .frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.tertiary)
    }

    // MARK: - Transport

    private var controls: some View {
        HStack(spacing: 20) {
            Button { media.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(NotchButtonStyle(size: 30))
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 40, prominent: true))
            Button { media.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(NotchButtonStyle(size: 30))
        }
        .frame(maxWidth: .infinity)
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
