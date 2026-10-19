import SwiftUI

/// Placeholder shown while artwork is on its way. The system publishes the new
/// title before it has fetched the new cover, so without this the panel would
/// sit on an empty grey square for a moment on every track change.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = 14
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.55)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

/// Three bars that breathe while something is playing — a glanceable "live"
/// marker next to the source name.
struct EqualizerBars: View {
    var isAnimating: Bool
    @State private var up = false

    private let low: [CGFloat] = [4, 7, 5]
    private let high: [CGFloat] = [10, 3, 8]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Theme.tertiary)
                    .frame(width: 2, height: up ? high[index] : low[index])
                    .animation(
                        isAnimating
                            ? .easeInOut(duration: 0.44)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12)
                            : .easeOut(duration: 0.2),
                        value: up
                    )
            }
        }
        .frame(height: 10, alignment: .bottom)
        .onAppear { up = isAnimating }
        .onChange(of: isAnimating) { _, playing in up = playing }
    }
}
