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

    /// Stable across a screen-parameter-change notification even though
    /// AppKit hands out a fresh `NSScreen` instance for the same physical
    /// display every time — the one thing worth keying a panel on when
    /// reconciling before/after a reconfiguration.
    var displayID: CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Size of the fully expanded panel body.
    let expandedSize = CGSize(width: 620, height: 208)
    /// Slack around the panel so the concave shoulders and shadow are not clipped.
    let windowPadding = NSEdgeInsets(top: 0, left: 40, bottom: 44, right: 40)

    /// One entry per connected screen — every display gets its own notch, real
    /// or synthetic, so the panel is reachable wherever the pointer happens to
    /// be.
    static func all() -> [NotchGeometry] {
        NSScreen.screens.map(geometry(for:))
    }

    static func geometry(for screen: NSScreen) -> NotchGeometry {
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
        return NotchGeometry(
            screen: screen,
            notchSize: CGSize(width: 180, height: max(NSStatusBar.system.thickness, 24)),
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

    /// Hover target while collapsed, in global screen coordinates. Slightly
    /// taller than the notch so the panel opens just before the pointer lands.
    var hoverRect: CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - notchSize.width / 2 - 6,
            y: screen.frame.maxY - notchSize.height - 4,
            width: notchSize.width + 12,
            height: notchSize.height + 4
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
