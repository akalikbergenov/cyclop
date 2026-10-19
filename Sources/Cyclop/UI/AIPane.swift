import SwiftUI

/// Claude at a glance: how much of the plan's limits is left, what the work
/// would have cost on the API, and whether a turn is running right now.
struct AIPane: View {
    @ObservedObject var claude: ClaudeUsageStore
    @ObservedObject private var config = ConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            limits
            Spacer(minLength: 8)
            if config.aiShowsSpending {
                spending
            }
            if config.aiShowsStatus, let status = claude.status {
                statusLine(status)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .animation(Theme.contentAnimation, value: claude.status == nil)
    }

    // MARK: - Limits

    @ViewBuilder
    private var limits: some View {
        if let limits = claude.limits {
            VStack(spacing: 7) {
                ForEach(limits.windows) { window in
                    limitRow(window)
                }
            }
        } else if claude.spending != nil {
            // Read once at least, and the Claude app has nothing to say.
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(claude.hasHistory ? localized("No recent limits from the Claude app") : localized("No limits from the Claude app yet"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Text("The app records them while its menu bar icon is on.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.top, 6)
        } else {
            VStack(spacing: 7) {
                ForEach(0..<2, id: \.self) { _ in
                    SkeletonBox(cornerRadius: 4).frame(height: 14)
                }
            }
        }
    }

    private func limitRow(_ window: ClaudeUsage.Window) -> some View {
        HStack(spacing: 10) {
            Text(title(for: window.kind))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule()
                        .fill(tint(for: window.usedPercent))
                        .frame(width: geo.size.width * window.usedPercent / 100)
                }
            }
            .frame(height: 5)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 36, alignment: .trailing)
            HStack(spacing: 3) {
                if let resets = window.resetsAt {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                    Text(Self.countdown(to: resets, from: claude.now))
                }
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .frame(width: 96, alignment: .leading)
        }
    }

    private func title(for kind: ClaudeUsage.Window.Kind) -> String {
        switch kind {
        case .session: return localized("Session")
        case .weekly: return localized("Week")
        case .weeklyOpus: return localized("Week · Opus")
        case .weeklySonnet: return localized("Week · Sonnet")
        }
    }

    /// White until the limit is close: colour is for the one row that needs
    /// a look, not for every row that has a number.
    private func tint(for used: Double) -> Color {
        if used >= 90 { return Color(red: 1, green: 0.42, blue: 0.38) }
        if used >= 75 { return Color(red: 1, green: 0.72, blue: 0.3) }
        return Color.white.opacity(0.85)
    }

    /// The calendar's wording, which is already abbreviated to fit the strip.
    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return localized("any moment") }
        if minutes < 60 { return localized("in %d min", minutes) }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? localized("in %d h", hours) : localized("in %d h %d min", hours, rest)
        }
        return localized("in %d d", Int((Double(hours) / 24).rounded()))
    }

    // MARK: - Spending

    @ViewBuilder
    private var spending: some View {
        HStack(spacing: 0) {
            stat(localized("Today"), claude.spending?.today)
            stat(localized("7 days"), claude.spending?.week)
            stat(localized("30 days"), claude.spending?.month)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func stat(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.tertiary)
            Group {
                if let value {
                    Text(Self.dollars(value))
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func dollars(_ value: Double) -> String {
        value >= 1000 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    // MARK: - Status

    private func statusLine(_ status: ClaudeUsageStore.Status) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
                .frame(width: 6, height: 6)
                .modifier(Pulse())
            Text(statusText(status))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }

    /// "Working · 14.4k tokens · 14:35", the way Claude Code's own spinner
    /// counts: output tokens of the turn, and its time so far.
    private func statusText(_ status: ClaudeUsageStore.Status) -> String {
        var parts = [localized("Working"), localized("%@ tokens", Self.tokens(status.outputTokens)),
                     Self.elapsed(claude.now.timeIntervalSince(status.start))]
        if status.sessions > 1 { parts.append(localized("%d sessions", status.sessions)) }
        return parts.joined(separator: " · ")
    }

    static func tokens(_ count: Int) -> String {
        count < 1000 ? "\(count)" : String(format: "%.1fk", Double(count) / 1000)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A slow breath on the status dot, so "working" reads as live at a glance.
private struct Pulse: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// When the Claude app last wrote its limits, for the panel header. Observes
/// the store on its own, like the notes counter: the model does not forward
/// this store, so the whole panel is not redrawn every tick.
struct AIHeaderBadge: View {
    @ObservedObject var claude: ClaudeUsageStore

    var body: some View {
        if let checked = claude.limits?.checkedAt {
            Text(Self.age(of: checked, now: claude.now))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return localized("checked just now") }
        if minutes < 60 { return localized("checked %d min ago", minutes) }
        let hours = minutes / 60
        if hours < 24 { return localized("checked %d h ago", hours) }
        return localized("checked %d d ago", hours / 24)
    }
}
