import AppKit
import SwiftUI

/// The island's right wing, drawn the way the iPhone draws it: seven thin
/// bars on a centre line, in the colour of the cover.
///
/// With the live equalizer on, the bars follow the sound — the bass bands in
/// the middle, the treble towards the edges, which gives the same tall-centre
/// shape the phone has. Without it, or before the meter has heard anything,
/// they breathe on their own, and a paused track lays them down to dots.
struct IslandWaveform: View {
    @ObservedObject var media: MediaController
    @ObservedObject var meter: AudioLevelMeter

    @State private var tint = Color.white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bars = 7
    /// Which band each bar shows, left to right: bass in the middle.
    private static let bandOrder = [5, 3, 1, 0, 2, 4, 6]
    private let barWidth: CGFloat = 2
    private let spacing: CGFloat = 2
    private let height: CGFloat = 16

    var body: some View {
        Group {
            if let levels = meter.levels, media.isPlaying {
                bars { index in level(fromBands: levels, at: index) }
                    .animation(.linear(duration: 1.0 / 30), value: levels)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !media.isPlaying || reduceMotion)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    bars { index in idleLevel(index, at: time) }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: media.isPlaying)
        .onAppear { tint = Self.tint(of: media.artwork) }
        .onChange(of: media.artwork) { _, image in
            withAnimation(Theme.artworkAnimation) { tint = Self.tint(of: image) }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ level: @escaping (Int) -> CGFloat) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth, height: barHeight(level(index)))
            }
        }
        .frame(height: height)
    }

    /// Edges reach lower than the middle, like the phone's envelope.
    private func reach(_ index: Int) -> CGFloat {
        let centre = CGFloat(Self.bars - 1) / 2
        return 1 - abs(CGFloat(index) - centre) / centre * 0.45
    }

    private func barHeight(_ level: CGFloat) -> CGFloat {
        guard media.isPlaying, !reduceMotion else { return barWidth }
        // A quiet band is a short stroke, not a dot: dots mean "paused".
        return max(barWidth * 1.75, height * min(1, level))
    }

    private func level(fromBands levels: [Float], at index: Int) -> CGFloat {
        let band = Self.bandOrder[index]
        guard band < levels.count else { return 0 }
        return CGFloat(levels[band]) * reach(index)
    }

    /// Two slow waves per bar at unrelated rates, so the pattern never visibly
    /// repeats.
    private func idleLevel(_ index: Int, at time: TimeInterval) -> CGFloat {
        let i = Double(index)
        let wave = 0.45 + 0.3 * sin(time * (5.1 + i * 1.3) + i * 1.7)
            + 0.2 * sin(time * (8.3 - i * 0.9) + i * 0.6)
        return CGFloat(0.2 + 0.8 * min(1, max(0, wave))) * reach(index)
    }

    /// The cover's average colour, lifted so it reads on black. A grey cover
    /// gives white, which is what the island would show without one.
    static func tint(of image: NSImage?) -> Color {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .white }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.15 else { return .white }
        return Color(hue: hue, saturation: min(saturation, 0.7), brightness: max(brightness, 0.85))
    }
}
