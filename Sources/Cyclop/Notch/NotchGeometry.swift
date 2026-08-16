import AppKit

/// Physical description of the notch (or a synthetic one on Macs without it)
/// plus every derived rect the panel needs, all in screen coordinates.
struct NotchGeometry {
    let screen: NSScreen
    /// Size of the physical notch in points.
    let notchSize: CGSize
    /// Horizontal centre of the notch, in global screen coordinates.
    let notchCenterX: CGFloat
    /// True when the display actually has a notch cut into it.
    let isPhysical: Bool

    /// Metrics of the tab rail that do not depend on the notch. `railIconHeight`
    /// is not among them — see below.
    static let railSpacing: CGFloat = 4
    /// Gap between the rail and the bottom edge of the body.
    static let bodyBottomPadding: CGFloat = 14

    /// Size of the fully expanded panel body. Held constant across every Mac:
    /// letting it follow the header made two people on the very same model
    /// see two different heights, just from different display-scaling
    /// settings — 38 pt against 32 for the same physical notch, an 11 pt
    /// spread from one slider (#27). What differs between Macs lives in
    /// `railIconHeight` instead, which is the one thing in the body actually
    /// free to give.
    let expandedSize = CGSize(width: 620, height: 208)

    /// Body for the teleprompter, the one tab that asks for more.
    ///
    /// Same width, so the panel does not change shape sideways — only the
    /// bottom edge moves, and it moves away from the notch rather than around
    /// it. The height is the smallest that fits a paragraph at a size readable
    /// without focusing: below this the tab shows the current line and the next
    /// one, which is a countdown, not a script.
    static let tallBodyHeight: CGFloat = 400
    var tallExpandedSize: CGSize {
        CGSize(width: expandedSize.width, height: Self.tallBodyHeight)
    }
    /// Tallest body any tab can ask for. The window is cut to this once and
    /// never resized: it is transparent outside the visible panel, and what is
    /// clickable is decided separately by the active rect.
    var maxBodyHeight: CGFloat { max(expandedSize.height, Self.tallBodyHeight) }

    /// What the body has left for content on an ordinary tab, once the header
    /// and the padding beneath are taken out.
    ///
    /// The rails are held to this even on the tab that is taller, so the icons
    /// stay at the same height on every tab. Centred in the body instead, they
    /// slid down by half the difference — 96 pt — the moment the teleprompter
    /// opened, which put the icon just clicked well below the pointer that had
    /// clicked it.
    var standardContentHeight: CGFloat {
        expandedSize.height - notchSize.height - Self.bodyBottomPadding
    }

    /// Height each rail icon gets. A ceiling, not a constant: six icons at
    /// the full 24 pt plus the five 4 pt gaps between them is 164 pt, and
    /// the body only has `expandedSize.height − notchSize.height −
    /// bodyBottomPadding` left to give the rail once the header — the notch
    /// itself — and the padding beneath are taken out of the fixed 208.
    /// Rounded down rather than to the nearest point: a rail that asks for
    /// more than it is given should visibly yield, not overflow by a
    /// fraction that clips it.
    var railIconHeight: CGFloat {
        let icons = CGFloat(NotchViewModel.Tab.leftRail.count)
        let available = expandedSize.height - notchSize.height - Self.bodyBottomPadding
        let ceiling = (available - (icons - 1) * Self.railSpacing) / icons
        return min(24, ceiling).rounded(.down)
    }

    /// Slack around the panel so the concave shoulders and shadow are not clipped.
    let windowPadding = NSEdgeInsets(top: 0, left: 40, bottom: 44, right: 40)

    /// Stable name for the display this geometry was cut from. AppKit hands
    /// out a fresh `NSScreen` for the same monitor on every reconfiguration,
    /// so this is the one thing worth keying a panel on — an index into
    /// `NSScreen.screens` is not, because that array reorders too.
    var displayID: CGDirectDisplayID? { screen.displayID }

    /// Persisted switch for every display past the first. Defaults to on: the
    /// panel is meant to be wherever the pointer is, so this is the way to
    /// pull it back to one screen, not the way to ask for the rest.
    static let allDisplaysKey = "showOnAllDisplays"
    /// Posted when that switch changes, so the panels are rebuilt at once
    /// rather than at the next relaunch.
    static let allDisplaysChanged = Notification.Name("CyclopShowOnAllDisplaysChanged")

    static var showsOnAllDisplays: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: allDisplaysKey) != nil else { return true }
            return defaults.bool(forKey: allDisplaysKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: allDisplaysKey)
            NotificationCenter.default.post(name: allDisplaysChanged, object: nil)
        }
    }

    /// Every display the panel should stand on.
    ///
    /// Switched off, that is the screen with a physical notch if one is
    /// attached and the main display otherwise — the rule from before there
    /// was more than one screen to choose between.
    static func all() -> [NotchGeometry] {
        // A mirrored display repeats another one's picture, so a panel of its
        // own would be a second copy of the same notch, drawn in the same
        // place, with a second pointer timer behind it.
        let screens = NSScreen.screens.filter { !$0.isMirroring }
        guard showsOnAllDisplays else {
            let primary = screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
            return primary.map { [current(on: $0)] } ?? []
        }
        return screens.map(current(on:))
    }

    static func current(on screen: NSScreen) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(
                screen: screen,
                notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                notchCenterX: screen.frame.minX + left.width + width / 2,
                isPhysical: true
            )
        }

        // No notch: pretend there is one the size of a typical MacBook cutout so
        // the app still works on external displays and pre-2021 machines.
        //
        // The height has to be the menu bar's own, not `NSStatusBar.thickness`:
        // the two disagree by several points (22 against 30 on a 13" M1 running
        // macOS 26), and the shape is drawn filled black, so anything short of
        // the bar's height reads as a tab stuck onto the menu bar rather than a
        // cutout of it. `visibleFrame` is what the menu bar actually took —
        // measured, not assumed. It collapses to zero when the bar auto-hides,
        // which is what the floor is for.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            screen: screen,
            notchSize: CGSize(width: 180, height: max(menuBarHeight, NSStatusBar.system.thickness, 24)),
            notchCenterX: screen.frame.midX,
            isPhysical: false
        )
    }

    /// True when nothing that affects the panel has moved. Screen-parameter
    /// notifications fire for plenty of reasons that leave the notch exactly
    /// where it was, and rebuilding on those would throw away the open state
    /// and the selected tab.
    func matches(_ other: NotchGeometry) -> Bool {
        screen.frame == other.screen.frame
            && notchSize == other.notchSize
            && notchCenterX == other.notchCenterX
            && isPhysical == other.isPhysical
    }

    // MARK: - Derived frames

    var windowSize: CGSize {
        CGSize(
            width: expandedSize.width + windowPadding.left + windowPadding.right,
            height: maxBodyHeight + windowPadding.bottom
        )
    }

    /// Panel frame in global screen coordinates, flush with the top of the display.
    var windowFrame: CGRect {
        CGRect(
            x: notchCenterX - windowSize.width / 2,
            y: screen.frame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    /// `CGRect.contains` treats `maxY` as exclusive, and the pointer parks on
    /// exactly `screen.frame.maxY` whenever it is thrown at the top of the
    /// display — which is precisely how one reaches the notch. Every rect that
    /// touches the top edge is grown past it so that position counts as inside.
    private func includingTopEdge(_ rect: CGRect) -> CGRect {
        guard rect.maxY >= screen.frame.maxY else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2)
    }

    /// Rect the content occupies inside the window, in screen coordinates.
    func contentScreenRect(for size: CGSize) -> CGRect {
        includingTopEdge(contentRect(for: size).offsetBy(dx: windowFrame.minX, dy: windowFrame.minY))
    }

    /// Rect the content occupies inside the window, in AppKit window coordinates.
    func contentRect(for size: CGSize) -> CGRect {
        CGRect(
            x: (windowSize.width - size.width) / 2,
            y: windowSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Depth of the collapsed target, measured down from the top edge.
    ///
    /// A real notch is a hole: the whole of it can be claimed, because there is
    /// nothing underneath to claim it from. A synthetic one is cut out of a
    /// working menu bar — and the middle of the bar is where status items pile
    /// up once there are a few (measured on a 13" M1: they start at x≈757 while
    /// the synthetic notch spans 630…810). Claiming the full bar height there
    /// puts the panel in front of icons the user is aiming at. A strip along the
    /// very top edge is reached by throwing the pointer up — the same gesture as
    /// ever — while a pointer travelling to an icon stays below it.
    var collapsedDepth: CGFloat { isPhysical ? notchSize.height : 8 }

    /// Size of the collapsed target: the notch itself, or the strip above.
    var collapsedSize: CGSize { CGSize(width: notchSize.width, height: collapsedDepth) }

    /// Hover target while collapsed, in global screen coordinates. Slightly
    /// taller than the notch so the panel opens just before the pointer lands.
    var hoverRect: CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - notchSize.width / 2 - 6,
            y: screen.frame.maxY - collapsedDepth - (isPhysical ? 4 : 0),
            width: notchSize.width + 12,
            height: collapsedDepth + (isPhysical ? 4 : 0)
        ))
    }

    /// Band along the top of the display in which pointer sampling runs at
    /// full rate. Deep enough that a pointer heading for the notch is always
    /// noticed before it arrives.
    var warmZone: CGRect {
        includingTopEdge(CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - 260,
            width: screen.frame.width,
            height: 260
        ))
    }

    /// Area that keeps the panel open while expanded, in global screen coordinates.
    var expandedHoverRect: CGRect { hoverRect(for: expandedSize) }

    /// Taken for the body actually on screen, not for the standard one: on the
    /// teleprompter the panel reaches 400 pt down, and a rect cut for 208 would
    /// call the pointer "away" halfway through the tab it is resting on.
    func hoverRect(for body: CGSize) -> CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - body.width / 2 - 12,
            y: screen.frame.maxY - body.height - 12,
            width: body.width + 24,
            height: body.height + 12
        ))
    }
}

extension NSScreen {
    /// The display behind this screen, named the way the window server names
    /// it — the same number across every reconfiguration.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// True when this screen only repeats what another display already shows.
    var isMirroring: Bool {
        guard let displayID else { return false }
        return CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
    }
}
