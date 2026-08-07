import AppKit
import SwiftUI
import Translation

/// The strip of tools under a chosen region.
struct ShotToolbarView: View {
    @ObservedObject var document: ShotDocument
    var isBusy: Bool
    var onRecognize: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void

    /// What the pointer is resting on, spelled out at the end of the strip.
    ///
    /// A real tooltip would be the obvious answer, and it is the one that does
    /// not arrive: `help(_:)` is delivered by the window server to a window
    /// that owns the pointer in the ordinary way, and this overlay sits at
    /// screen-saver level over a frozen screen with the pointer captured as a
    /// crosshair. So the strip says it itself — instantly, with no dwell, which
    /// is better anyway for a toolbar somebody is scanning in a hurry.
    @State private var hovered: String?

    /// The palette. Six, because a screenshot annotation needs a colour that
    /// stands out against what is underneath and nothing more — a full colour
    /// picker here is a menu to get lost in with the shutter still open.
    private static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black,
    ]

    var body: some View {
        HStack(spacing: 6) {
            button("xmark", localized("Cancel"), action: onCancel)
                .foregroundStyle(Color.white.opacity(0.8))

            divider

            ForEach(ShotTool.allCases) { tool in
                button(tool.symbol, tool.title, active: document.tool == tool) {
                    document.tool = tool
                }
            }

            divider

            ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, color in
                swatch(color)
            }

            widthPicker

            divider

            button("arrow.uturn.backward", localized("Undo")) { document.undo() }
                .disabled(!document.canUndo)
                .opacity(document.canUndo ? 1 : 0.35)

            divider

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                button("text.viewfinder", localized("Recognise Text"), action: onRecognize)
            }

            divider

            button("square.and.arrow.down", localized("Save") + " ⌘S", action: onSave)
            Button(action: onCopy) {
                Text(localized("Copy"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? localized("Copy to the buffer and close") + " ⌘C" : nil }
            .help(localized("Copy to the buffer and close"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { caption }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// Sits above the strip rather than inside it, so nothing shifts when it
    /// appears and the strip keeps one width all session.
    @ViewBuilder
    private var caption: some View {
        if let hovered {
            Text(hovered)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.black.opacity(0.9))
                )
                .fixedSize()
                .offset(y: -24)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }

    private func button(
        _ symbol: String,
        _ help: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.black : Color.white)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.white : Color.white.opacity(0.001))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? help : nil }
        .help(help)
    }

    private func swatch(_ color: NSColor) -> some View {
        let isCurrent = document.color == color
        return Button {
            document.color = color
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(isCurrent ? 0.95 : 0.25),
                        lineWidth: isCurrent ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    /// Thickness, on a slider.
    ///
    /// Three fixed weights were quicker to hit and too coarse to be useful: a
    /// highlighter wants a fat stroke and an arrow pointing at one word in a
    /// screenshot wants a thin one, and neither is "medium". The dot on the
    /// left previews what the number means, at the size it means.
    private var widthPicker: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: document.color))
                .frame(width: max(document.lineWidth, 2), height: max(document.lineWidth, 2))
                .frame(width: 16, height: 20)
            Slider(
                value: Binding(
                    get: { Double(document.lineWidth) },
                    set: { document.lineWidth = CGFloat($0) }
                ),
                in: 1...20,
                step: 1
            )
            .controlSize(.mini)
            .frame(width: 70)
            .onHover { hovered = $0 ? localized("Thickness") : nil }
            Text("\(Int(document.lineWidth))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 14, alignment: .leading)
        }
        .padding(.leading, 4)
    }

}
