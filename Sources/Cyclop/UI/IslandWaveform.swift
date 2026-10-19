import AppKit
import SwiftUI

/// The island's right wing, drawn the way the iPhone draws it: five thin
/// bars on a centre line, in the colour of the cover. The wing is as wide as
/// the cover on the left, so the two weigh the same.
///
/// With the live equalizer on, the bars follow the sound — the bass bands in
/// the middle, the treble towards the edges, which gives the same tall-centre
/// shape the phone has. Without it, or before the meter has heard anything,
/// they breathe on their own, and a paused track lays them down to dots.
struct IslandWaveform: View {
    @ObservedObject var media: MediaController
    @ObservedObject var meter: AudioLevelMeter
    /// The cover's side; the bars fill a box of the same width.
    let side: CGFloat

    @State private var tint = Color.white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bars = 5
    /// Which band each bar shows, left to right: bass in the middle.
    private static let bandOrder = [3, 1, 0, 2, 4]
    private var barWidth: CGFloat { (side / CGFloat(Self.bars * 2 - 1)).rounded(.down) }
    private var spacing: CGFloat { (side - barWidth * CGFloat(Self.bars)) / CGFloat(Self.bars - 1) }
    private var height: CGFloat { side * 0.7 }

    /// Kept across frames: each bar's position and velocity.
    @State private var springs = BarSprings(count: bars)

    var body: some View {
        Group {
            if media.isPlaying, !reduceMotion {
                // Every frame the display draws, not every meter reading: the
                // springs move between readings, so nothing steps.
                TimelineView(.animation) { context in
                    let date = context.date
                    let targets = (0..<Self.bars).map { index in
                        if let levels = meter.levels { return level(fromBands: levels, at: index) }
                        return idleLevel(index, at: date.timeIntervalSinceReferenceDate)
                    }
                    let heights = springs.step(toward: targets, at: date)
                    bars { heights[$0] }
                }
            } else {
                bars { _ in 0 }
                    .onAppear { springs.reset() }
            }
        }
        .animation(.easeOut(duration: 0.25), value: media.isPlaying)
        .onAppear { tint = Self.tint(of: media.artwork) }
        .onChange(of: media.artwork) { _, image in
            withAnimation(Theme.artworkAnimation) { tint = Self.tint(of: image) }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ level: (Int) -> CGFloat) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array((0..<Self.bars).map(level).enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth, height: barHeight(value))
            }
        }
        .frame(width: side, height: height)
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

/// Bars that follow their targets the way Apple's interfaces follow a finger:
/// a critically damped spring per bar, set by how quickly it responds rather
/// than by stiffness and damping — the model from WWDC 2018's "Designing
/// Fluid Interfaces". A new target bends the motion instead of restarting it,
/// so readings arriving thirty times a second still draw as one curve, at
/// whatever rate the display runs.
final class BarSprings {
    /// Seconds to settle most of the way. Short enough to keep the beat,
    /// long enough to round off the steps between readings.
    private let response: Double = 0.16
    private var position: [Double]
    private var velocity: [Double]
    private var last: Date?

    init(count: Int) {
        position = Array(repeating: 0, count: count)
        velocity = Array(repeating: 0, count: count)
    }

    func reset() {
        position = position.map { _ in 0 }
        velocity = velocity.map { _ in 0 }
        last = nil
    }

    func step(toward targets: [CGFloat], at date: Date) -> [CGFloat] {
        // A long gap — the island was away — is not a fall to integrate.
        let elapsed = min(1.0 / 20, max(0, last.map { date.timeIntervalSince($0) } ?? 0))
        last = date
        let stiffness = pow(2 * .pi / response, 2)
        let damping = 4 * .pi / response
        // Small fixed steps keep the spring stable at any frame rate.
        var remaining = elapsed
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 240)
            for index in position.indices where index < targets.count {
                let force = -stiffness * (position[index] - Double(targets[index])) - damping * velocity[index]
                velocity[index] += force * dt
                position[index] += velocity[index] * dt
            }
            remaining -= dt
        }
        return position.map { CGFloat(max(0, $0)) }
    }
}
