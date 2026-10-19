import AppKit
import SwiftUI

/// The island's right wing, the way the iPhone draws it: a few rounded bars
/// standing on a centre line, taller in the middle than at the edges, each
/// breathing at its own pace, in the colour of the cover.
///
/// Decorative, not a meter — there is no audio here to measure, and reading
/// any would take a permission. A paused track lays the bars down to dots.
struct IslandWaveform: View {
    @ObservedObject var media: MediaController

    @State private var tint = Color.white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bars = 4
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2.5
    private let height: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !media.isPlaying || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(width: barWidth, height: barHeight(index, at: time))
                }
            }
            .frame(height: height)
        }
        .animation(.easeOut(duration: 0.25), value: media.isPlaying)
        .onAppear { tint = Self.tint(of: media.artwork) }
        .onChange(of: media.artwork) { _, image in
            withAnimation(Theme.artworkAnimation) { tint = Self.tint(of: image) }
        }
        .accessibilityHidden(true)
    }

    /// Two slow waves per bar at unrelated rates, so the pattern never visibly
    /// repeats; the inner bars reach higher than the outer ones.
    private func barHeight(_ index: Int, at time: TimeInterval) -> CGFloat {
        guard media.isPlaying, !reduceMotion else { return barWidth }
        let centre = Double(bars - 1) / 2
        let reach = 1 - abs(Double(index) - centre) / (centre + 1) * 0.55
        let i = Double(index)
        let wave = 0.5 + 0.3 * sin(time * (5.1 + i * 1.3) + i * 1.7)
            + 0.2 * sin(time * (8.3 - i * 0.9) + i * 0.6)
        let level = min(1, max(0, wave)) * reach
        return max(barWidth, height * CGFloat(0.3 + 0.7 * level))
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
