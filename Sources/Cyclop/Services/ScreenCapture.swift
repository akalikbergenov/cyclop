import AppKit
import ScreenCaptureKit

/// Takes the still picture the shot editor is drawn on top of.
///
/// The whole screen is grabbed once, up front, and the selection is cropped out
/// of that image afterwards. Grabbing only the chosen rectangle would be less
/// work but the wrong picture: by the time the user has finished dragging, the
/// clock has ticked, a notification has slid in, and a video has moved on. What
/// is being selected has to be the frozen frame the user is looking at, so the
/// overlay shows that frame and every crop comes out of it.
enum ScreenCapture {
    /// Whether macOS will hand over screen contents at all.
    ///
    /// Read without prompting, like `Paster.isTrusted`: the prompt belongs to
    /// the moment the user asks for a screenshot, not to launch.
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Puts up the system prompt. Returns what it already knew — the answer
    /// arrives by the user restarting the app, not by this call.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens Privacy & Security → Screen & System Audio Recording.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    struct Frame {
        let screen: NSScreen
        let image: CGImage
        /// Pixels per point, so a rect chosen in screen coordinates can be cut
        /// out of an image that is twice as dense.
        let scale: CGFloat
        /// Every ordinary window on this display, front to back, in AppKit
        /// screen coordinates. What the pointer snaps to.
        let windows: [CGRect]
    }

    /// One frozen frame per display.
    ///
    /// Cyclop's own windows are excluded, and that is not cosmetic: the panel
    /// hangs over the notch on every space, so without this every screenshot of
    /// the top of the screen would have a black tab baked into it.
    static func frames() async throws -> [Frame] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ourApp = content.applications.first {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        let windows = visibleWindows()

        var frames: [Frame] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }

            let filter: SCContentFilter
            if let ourApp {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: [ourApp],
                    exceptingWindows: []
                )
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }

            let configuration = SCStreamConfiguration()
            // Native pixels, not points. A Retina screenshot that came back at
            // half the resolution would be a blurry thing to annotate and a
            // hopeless thing to read text out of — OCR lives on pixel density.
            let scale = screen.backingScaleFactor
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            frames.append(Frame(
                screen: screen,
                image: image,
                scale: scale,
                // Windows are listed front to back already; kept in that order
                // so the topmost one under the pointer is simply the first
                // match. Only those that actually overlap this display.
                windows: windows.filter { $0.intersects(screen.frame) }
            ))
        }
        return frames
    }
}

extension ScreenCapture {
    /// Windows the user can actually see, front to back, in AppKit screen
    /// coordinates.
    ///
    /// Two things have to be true, and ScreenCaptureKit's list gets neither
    /// quite right on its own. The window must be on *this* desktop —
    /// `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` answers that,
    /// because the window server knows which space is showing — and it must
    /// not be buried: a full-screen window in front leaves a dozen windows
    /// behind it that are still "on screen" as far as any list is concerned,
    /// and offering to snap to one the user cannot see is offering to
    /// screenshot something that is not there.
    static func visibleWindows() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        // CoreGraphics counts from the top left of the main display; AppKit
        // counts from the bottom left. One flip, against the height both
        // systems agree on.
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height

        // Front to back, which is the order the list already comes in.
        var candidates: [CGRect] = []
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ourPID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 40, height > 40 else { continue }
            // An alpha of zero is a window that is there and invisible, which
            // several apps keep around as a hidden helper.
            if let alpha = entry[kCGWindowAlpha as String] as? CGFloat, alpha < 0.05 { continue }
            candidates.append(CGRect(x: x, y: mainHeight - y - height, width: width, height: height))
        }

        // Drop whatever is completely hidden behind what is in front of it.
        var visible: [CGRect] = []
        for candidate in candidates {
            if !isBuried(candidate, under: visible) { visible.append(candidate) }
        }
        return visible
    }

    /// Whether every part of `rect` is behind something already accepted.
    ///
    /// Sampled rather than computed exactly. An exact answer means subtracting
    /// a list of rectangles from a rectangle and asking whether anything is
    /// left, which is real region arithmetic for a question that only has to
    /// be right about the case that matters: something in front covering the
    /// whole of something behind. A grid of points is right about that, cheap,
    /// and errs towards offering a window rather than hiding one.
    private static func isBuried(_ rect: CGRect, under front: [CGRect]) -> Bool {
        guard !front.isEmpty else { return false }
        let steps = 5
        for row in 0...steps {
            for column in 0...steps {
                let point = CGPoint(
                    x: rect.minX + rect.width * CGFloat(column) / CGFloat(steps),
                    y: rect.minY + rect.height * CGFloat(row) / CGFloat(steps)
                )
                // Nudged inwards, or the samples on the edge would count a
                // window that merely touches this one as covering it.
                let inside = CGPoint(
                    x: min(max(point.x, rect.minX + 1), rect.maxX - 1),
                    y: min(max(point.y, rect.minY + 1), rect.maxY - 1)
                )
                if !front.contains(where: { $0.contains(inside) }) { return false }
            }
        }
        return true
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

extension ScreenCapture.Frame {
    /// Cuts a rectangle given in global screen coordinates out of the frame.
    ///
    /// Two coordinate systems meet here and they disagree about which way is
    /// up: screen coordinates start at the bottom-left of the *main* display
    /// and grow upwards, images start at their own top-left and grow down.
    func crop(to rect: CGRect) -> CGImage? {
        let local = CGRect(
            x: (rect.minX - screen.frame.minX) * scale,
            y: (screen.frame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        guard local.width >= 1, local.height >= 1 else { return nil }
        return image.cropping(to: local)
    }
}
