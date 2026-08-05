import SwiftUI

enum Theme {
    static let openAnimation = Animation.spring(response: 0.27, dampingFraction: 0.82)
    static let contentAnimation = Animation.easeOut(duration: 0.16)

    /// How gently a tab switches when the rail hands it over. A free slider
    /// promises a precision nobody can actually place by eye or describe
    /// afterwards, so this is three named speeds instead — picked once from
    /// the menu bar and left alone.
    enum PaneSpeed: Int, CaseIterable {
        case quick, normal, smooth

        var title: String {
            switch self {
            case .quick: return localized("Quick")
            case .normal: return localized("Normal")
            case .smooth: return localized("Smooth")
            }
        }

        /// Scales every duration below. `normal` is today's feel, unchanged.
        var factor: Double {
            switch self {
            case .quick: return 0.5
            case .normal: return 1.0
            case .smooth: return 2.5
            }
        }
    }

    static let paneSpeedKey = "paneSpeed"

    static var paneSpeed: PaneSpeed {
        get {
            let stored = UserDefaults.standard.object(forKey: paneSpeedKey) as? Int
            return stored.flatMap(PaneSpeed.init(rawValue:)) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: paneSpeedKey) }
    }

    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long. Scaling both
    /// by the same factor keeps that ratio at every speed.
    static var paneAnimation: Animation { .easeOut(duration: 0.18 * paneSpeed.factor) }
    static var paneIn: Animation { .easeOut(duration: 0.20 * paneSpeed.factor).delay(0.04 * paneSpeed.factor) }
    static var paneOut: Animation { .easeIn(duration: 0.12 * paneSpeed.factor) }
    static let artworkAnimation = Animation.easeOut(duration: 0.28)

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22

    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let surface = Color.white.opacity(0.08)
    static let surfaceHover = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)
}

/// Flat, focus-free button used for every control in the panel.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 17 : 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(prominent ? Theme.surfaceHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Tracks hover without triggering layout changes in the parent.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        onHover(perform: action)
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
