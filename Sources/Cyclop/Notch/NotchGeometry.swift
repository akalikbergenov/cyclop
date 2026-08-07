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

    /// Size of the fully expanded panel body. Read from Settings when the
    /// geometry is measured, and frozen into this struct afterwards: every rect
    /// below is derived from it and the window's frame is built from those, so
    /// a size that could change underneath would describe a window that no
    /// longer exists. Changing it rebuilds the panel instead.
    let expandedSize: CGSize
    /// Slack around the panel so the concave shoulders and shadow are not clipped.
    let windowPadding = NSEdgeInsets(top: 0, left: 40, bottom: 44, right: 40)

    /// Measured on the main actor, because the sizes now come from Settings —
    /// which is where the user's numbers live, and those are main-actor state
    /// like everything else the panel is built from.
    @MainActor
    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let settings = Settings.shared
        let expanded = CGSize(width: settings.panelWidth, height: settings.panelHeight)

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(
                screen: screen,
                notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                notchCenterX: screen.frame.minX + left.width + width / 2,
                isPhysical: true,
                expandedSize: expanded
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
            // The width is the user's on a Mac without a cutout: there is no
            // physical fact to measure, only a shape the panel folds into, and
            // how wide that should be depends on how crowded their menu bar is.
            notchSize: CGSize(
                width: settings.notchWidth,
                height: max(menuBarHeight, NSStatusBar.system.thickness, 24)
            ),
            notchCenterX: screen.frame.midX,
            isPhysical: false,
            expandedSize: expanded
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
            && expandedSize == other.expandedSize
    }

    // MARK: - Derived frames

    var windowSize: CGSize {
        CGSize(
            width: expandedSize.width + windowPadding.left + windowPadding.right,
            height: expandedSize.height + windowPadding.bottom
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
    var expandedHoverRect: CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - expandedSize.width / 2 - 12,
            y: screen.frame.maxY - expandedSize.height - 12,
            width: expandedSize.width + 24,
            height: expandedSize.height + 12
        ))
    }
}
