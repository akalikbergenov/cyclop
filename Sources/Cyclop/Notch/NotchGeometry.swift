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
    /// True when menu bar icons lie under the notch we drew.
    ///
    /// This, and not the absence of a real notch, is what the collapsed target
    /// is narrowed for. A synthetic notch on a narrow display lands in the
    /// middle of the bar where the icons pile up; on a wide one the same notch
    /// sits hundreds of points clear of them, and the caution then costs
    /// everything and buys nothing — a notch drawn 25 pt tall that answers the
    /// pointer in the top 8 of it. Measured per display, because it is a fact
    /// about that display and not about this Mac.
    let guardsIcons: Bool

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
                isPhysical: true,
                guardsIcons: false
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
        // Zero height means either of two things, and they want opposite
        // treatment: a display that carries no menu bar at all — a second
        // monitor without separate Spaces — or one whose bar is merely hidden
        // and comes back the moment the pointer arrives. The display that owns
        // the menu bar is `screens.first`, the one marked primary in
        // Arrangement, and it carries one whether it is showing or not.
        let hasMenuBar = menuBarHeight > 0 || screen.displayID == NSScreen.screens.first?.displayID
        // The right edge of the collapsed target, icons permitting.
        let reach = screen.frame.midX + 90 + 6
        return NotchGeometry(
            screen: screen,
            notchSize: CGSize(width: 180, height: max(menuBarHeight, NSStatusBar.system.thickness, 24)),
            notchCenterX: screen.frame.midX,
            isPhysical: false,
            guardsIcons: hasMenuBar && (iconsBegin(on: screen) ?? .infinity) < reach
        )
    }

    /// Where the menu bar icons start on this display, in screen coordinates,
    /// or nil when it carries none.
    ///
    /// Status items are windows at the status level, and a window's frame is
    /// public even though its picture is not — so this is a measurement, and
    /// it needs no permission to take. Measured rather than guessed from the
    /// width of the display, because how far left the icons reach is a fact
    /// about how many the person has, and that is not something to assume:
    /// they start at x≈757 on one 13" Mac and at x≈1158 on another.
    private static func iconsBegin(on screen: NSScreen) -> CGFloat? {
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return nil }
        let level = Int(CGWindowLevelForKey(.statusWindow))
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return windows.compactMap { window -> CGFloat? in
            guard window[kCGWindowLayer as String] as? Int == level,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let height = bounds["Height"]
            else { return nil }
            // Quartz counts downward from the top of the primary display,
            // screens upward from its bottom.
            let middle = CGPoint(x: x, y: primaryTop - y - height / 2)
            return screen.frame.contains(middle) ? x : nil
        }.min()
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
            && guardsIcons == other.guardsIcons
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
    /// nothing underneath to claim it from. A synthetic one cut out of a
    /// working menu bar is the opposite — the middle of the bar is where status
    /// items pile up once there are a few (measured on a 13" M1: they start at
    /// x≈757 while the synthetic notch spans 630…810), and claiming the full
    /// bar height there puts the panel in front of icons the user is aiming at.
    /// A strip along the very top edge is reached by throwing the pointer up —
    /// the same gesture as ever — while a pointer travelling to an icon stays
    /// below it.
    ///
    /// A notch the icons do not reach has neither problem, so it is treated
    /// like the hole: it answers everywhere it is drawn.
    var collapsedDepth: CGFloat { guardsIcons ? 8 : notchSize.height }

    /// Size of the collapsed target: the notch itself, or the strip above.
    var collapsedSize: CGSize { CGSize(width: notchSize.width, height: collapsedDepth) }

    /// Hover target while collapsed, in global screen coordinates. Slightly
    /// taller than the notch so the panel opens just before the pointer lands.
    var hoverRect: CGRect {
        // The slack goes wherever the full depth does: it is what makes the
        // panel open just before the pointer lands, and it is only withheld
        // where a menu bar underneath would feel it.
        let slack: CGFloat = guardsIcons ? 0 : 4
        return includingTopEdge(CGRect(
            x: notchCenterX - notchSize.width / 2 - 6,
            y: screen.frame.maxY - collapsedDepth - slack,
            width: notchSize.width + 12,
            height: collapsedDepth + slack
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
