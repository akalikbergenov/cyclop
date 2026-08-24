import SwiftUI

/// A field of drifting, twinkling dots drawn where hidden text would be.
///
/// Deliberately not a blur. Small text under a small blur radius stays legible,
/// and a video encoder frequently makes it more legible rather than less; a
/// blur is also reversible when its radius is small. Here the string is never
/// drawn at all — it does not enter the view tree while it is hidden — so the
/// frame holds nothing to recover.
///
/// The field also fills the whole row instead of tracing the glyphs. Telegram
/// traces them, which looks better and gives away the length and the word
/// breaks of what is covered; for a password the length is half the answer.
struct SpoilerField: View {
    /// Dots per square point. Dense enough to read as a solid dusting at the
    /// sizes the panel uses, which are small. Turned down from the first cut
    /// (0.55): measured on the full notes editor, the field cost 35 % CPU at
    /// 30 fps — a fan-spinner on exactly the streams it exists for. At 0.4 and
    /// 20 fps the dust still reads as dust and the bill drops by two thirds.
    var density: Double = 0.4
    /// How many alpha steps the dots are sorted into. Every dot is its own
    /// ellipse, but they are filled a step at a time — a few fills per frame
    /// instead of a thousand, and the eye cannot tell the difference.
    var steps = 5
    /// Per-row, or every covered row draws the same dust and the column reads
    /// as one texture copied down the list instead of as noise.
    var seed: UInt64 = 0x9E3779B97F4A7C15

    var body: some View {
        // The dots are animated, so this view is alive only while the panel is
        // open — a folded panel has no content view at all, and the app's idle
        // cost stays where it was.
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .drawingGroup()
    }

    private func draw(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 1, size.height > 1 else { return }
        // The ceiling is what a whole covered pane runs into, not a row: at this
        // density a row asks for a few hundred dots and the notes tab for tens
        // of thousands. Capped, a large area thins out into a starfield instead
        // of dust, so the ceiling is set by what still draws in a frame rather
        // than by what a row needs.
        let count = min(Int(size.width * size.height * density), 7000)
        guard count > 0 else { return }

        // Seeded from a constant, so every frame lays the dots in the same
        // places: only their brightness and their small drift depend on time.
        // Keeping the positions in the generator rather than in @State means
        // nothing has to be rebuilt when the row changes size.
        var random = Splitmix64(seed: seed)
        var buckets = [Path](repeating: Path(), count: steps)

        for _ in 0..<count {
            let x = random.unit() * size.width
            let y = random.unit() * size.height
            let phase = random.unit() * 2 * .pi
            let speed = 1.1 + random.unit() * 2.4
            let radius = 0.45 + random.unit() * 0.5

            // Twinkle, plus a drift small enough to read as shimmer rather
            // than as motion.
            let brightness = 0.18 + 0.82 * abs(sin(time * speed + phase))
            let dx = sin(time * 0.7 + phase) * 0.7
            let dy = cos(time * 0.5 + phase) * 0.5

            let step = min(steps - 1, Int(brightness * Double(steps)))
            buckets[step].addEllipse(in: CGRect(
                x: x + dx - radius, y: y + dy - radius,
                width: radius * 2, height: radius * 2
            ))
        }

        for (index, path) in buckets.enumerated() where !path.isEmpty {
            let alpha = (Double(index) + 0.5) / Double(steps)
            context.fill(path, with: .color(.white.opacity(alpha * 0.85)))
        }
    }
}

/// Small, fast, and good enough for dust. `arc4random` would do too, but this
/// one is seedable, which is what keeps the dots from jumping every frame.
private struct Splitmix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// 0…1.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}

/// A string that is either shown or replaced by the dust — never both, and
/// never merely made transparent.
struct SpoilerText: View {
    let text: String
    let hidden: Bool
    var font: Font = .system(size: 11)
    var color: Color = .white
    /// Height of the field that stands in for the text, so a covered row is
    /// exactly as tall as an uncovered one.
    var height: CGFloat = 12
    /// Anything stable that differs between rows — the row's id will do. Not
    /// the text itself: identical strings would then draw identical dust, and
    /// "these two rows hold the same thing" is worth hiding too.
    var seed: UInt64 = 0x9E3779B97F4A7C15

    var body: some View {
        if hidden {
            SpoilerField(seed: seed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height)
                // Or the trailing spacer would split the row with it, and the
                // width of the covered area would follow the row's contents.
                .layoutPriority(1)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                // Announced rather than described: a screen reader must not be
                // the hole in a feature about not showing things.
                .accessibilityLabel(Text(localized("Hidden")))
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The eye that uncovers one row. Sits where a row's other controls sit and
/// appears on hover with them.
struct RevealEye: View {
    let hidden: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: hidden ? "eye" : "eye.slash")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
        .help(hidden ? Text(localized("Show")) : Text(localized("Hide")))
    }
}

/// Turns covering on or off for one section, from inside the tab it covers.
///
/// The menu bar keeps the switch that decides everything at once, in a hurry,
/// with the camera already running. This is the other half: while the tab is
/// open anyway, reaching for the menu to cover the very thing on screen is a
/// trip through two menus for a decision that belongs where it applies.
///
/// Inside the tab rather than in the panel header, because that strip lies
/// directly on the menu bar, where utilities like Ice watch for clicks with a
/// global monitor and fire on anything interactive placed there.
struct PrivacySwitch: View {
    @ObservedObject var privacy: PrivacyMode
    let section: PrivacyMode.Section

    private var covering: Bool { privacy.covers(section) }

    var body: some View {
        Button {
            privacy.setCovering(section, !covering)
        } label: {
            Image(systemName: covering ? "eye.slash.fill" : "eye")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(covering ? Color.white.opacity(0.8) : Theme.secondary)
        }
        .buttonStyle(.plain)
        // The switch in the snippets tab stands next to the search field, and a
        // focused field owns the I-beam over its own area: without a pointer of
        // its own the button would keep the caret while being clickable.
        .pointerStyle(.default)
        .help(covering ? localized("Show") : localized("Hide"))
    }
}
