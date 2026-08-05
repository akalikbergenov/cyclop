import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel

    private var isOpen: Bool { vm.isOpen || vm.isDropTargeted }
    private var size: CGSize { vm.bodySize }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

    var body: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(
                topRadius: topRadius,
                bottomRadius: isOpen ? Theme.openBottomRadius : Theme.collapsedBottomRadius
            )
            .fill(Color.black)
            .frame(width: size.width + 2 * topRadius, height: size.height)
            .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 18, y: 8)

            VStack(spacing: 0) {
                header
                if isOpen {
                    content
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.openAnimation, value: isOpen)
        .animation(Theme.paneAnimation, value: vm.tab)
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    private var header: some View {
        HStack(spacing: 0) {
            if isOpen {
                Text(vm.tab.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 16)
                    .id(vm.tab)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: vm.geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            if isOpen {
                trailing
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .frame(height: vm.geometry.notchSize.height)
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .media:
            HStack(spacing: 6) {
                if vm.media.track != nil {
                    EqualizerBars(isAnimating: vm.media.isPlaying)
                }
                Text(vm.media.sourceName ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(vm.clipboard.items.count)
        case .snippets:
            counter(vm.snippets.items.count)
        case .calendar:
            if let next = vm.calendar.next {
                Text(CalendarPane.countdown(to: next, from: vm.calendar.now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(next.isRunning ? Color.white.opacity(0.8) : Theme.tertiary)
            }
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .notes:
            NotesCounter(notes: vm.notes)
        }
    }

    @ViewBuilder
    private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Body

    private var content: some View {
        HStack(spacing: 14) {
            rail(for: NotchViewModel.Tab.leftRail)
            panes
            rail(for: NotchViewModel.Tab.rightRail)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Omitted entirely when every tab on this side is switched off — an
    /// empty rail would still claim its width and the spacing around it.
    @ViewBuilder
    private func rail(for tabs: [NotchViewModel.Tab]) -> some View {
        let visible = tabs.filter(vm.enabledTabs.contains)
        if !visible.isEmpty {
            Rail(vm: vm, tabs: visible)
        }
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.97))
                        .animation(Theme.paneIn),
                    removal: .opacity
                        .combined(with: .scale(scale: 1.02))
                        .animation(Theme.paneOut)
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .media:
            MediaPane(media: vm.media)
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: vm.isDropTargeted)
        case .clipboard:
            ClipboardPane(clipboard: vm.clipboard)
        case .calendar:
            CalendarPane(calendar: vm.calendar)
        case .snippets:
            SnippetsPane(snippets: vm.snippets, wantsKeyboard: $vm.wantsKeyboard)
        case .translate:
            TranslatePane(translator: vm.translator, wantsKeyboard: $vm.wantsKeyboard)
        case .notes:
            NotesPane(notes: vm.notes, wantsKeyboard: $vm.wantsKeyboard)
        }
    }
}

/// Watches the note store itself rather than reading through the view model:
/// notes are born and deleted inside the pane while this counter is on
/// screen, and the view model deliberately does not forward keystroke-driven
/// stores.
private struct NotesCounter: View {
    @ObservedObject var notes: NoteStore

    var body: some View {
        if !notes.notes.isEmpty {
            Text("\(notes.notes.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// Tab switcher.
///
/// Hovering switches tabs, but only after the pointer has stopped: a pointer
/// crossing the rail on its way somewhere else is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold is what separates "the mouse was flung across the top of the
/// screen" from "the mouse came to the notch" in `PointerWatcher`.
private struct Rail: View {
    @ObservedObject var vm: NotchViewModel
    /// Which icons this rail carries — there are two rails now, one per side.
    let tabs: [NotchViewModel.Tab]

    @State private var hovered: NotchViewModel.Tab?

    /// Long enough to swallow a pass-through, short enough that a deliberate
    /// hover still feels like it answered instantly.
    private let dwell = Duration.milliseconds(150)

    var body: some View {
        VStack(spacing: 4) {
            ForEach(tabs) { tab in
                Button {
                    vm.select(tab)
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(fill(for: tab))
                        )
                        .foregroundStyle(vm.tab == tab ? Color.white : Theme.tertiary)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        // A render-time transform. Growing the frame instead
                        // would re-lay out the rail on every hover, and layout
                        // that runs on pointer movement is exactly the kind
                        // that shows up as a stutter.
                        .scaleEffect(hovered == tab ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = tab
                    } else if hovered == tab {
                        hovered = nil
                    }
                }
            }
        }
        .frame(width: 30)
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(Theme.contentAnimation, value: hovered)
        // Moving to another icon cancels the pending switch along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, hovered != vm.tab else { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            vm.select(hovered)
        }
    }

    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if vm.tab == tab { return Theme.surfaceHover }
        return hovered == tab ? Theme.surface : .clear
    }
}
