import AppKit

/// Everything painted over the frozen screen: the dimming, the grid, the
/// offered window, the crop's frame and the annotations.
///
/// A view of its own only because of how layer-backed drawing stacks: the
/// picture is the canvas's layer contents, and a layer's own contents sit below
/// its sublayers, so anything drawn by the canvas itself would end up behind
/// the picture. It never takes a mouse event — `hitTest` sends every one
/// straight through to the canvas, which owns all the gestures.
final class ShotOverlayView: NSView {
    weak var canvas: ShotCanvasView?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        canvas?.drawOverlay(dirtyRect)
    }
}

/// The surface a shot is chosen and drawn on.
///
/// AppKit rather than SwiftUI, and not for nostalgia: this view is one long
/// mouse gesture from beginning to end. Pressing, dragging out a shape,
/// catching the shape by its edge afterwards and moving it, grabbing a corner
/// handle to resize it — all of that is hit-testing against a model and
/// redrawing, which is what an `NSView` is. The toolbar above it is SwiftUI,
/// where the buttons are.
final class ShotCanvasView: NSView {
    enum Phase {
        /// Dragging out the region. Everything outside it is dimmed.
        case choosing
        /// The region is settled and the tools are live.
        case editing
    }

    /// The frozen picture of this display, drawn full-bleed underneath.
    var frame_: ScreenCapture.Frame?
    var document: ShotDocument?

    private(set) var phase: Phase = .choosing
    /// In view coordinates, always standardised.
    private(set) var selection: CGRect = .zero
    /// How round the crop's corners are. Non-zero only when the region came
    /// from snapping to a window: macOS rounds window corners, and a shot of a
    /// window with square corners has a slice of somebody's wallpaper baked
    /// into each one.
    private(set) var cornerRadius: CGFloat = 0

    /// Windows on this display, front to back, in view coordinates.
    private var windows: [CGRect] = []
    /// The one under the pointer, offered for a click.
    private var snapTarget: CGRect?
    /// How round the offer is drawn — square for the whole screen, rounded for
    /// a window.
    private var snapCornerRadius: CGFloat = 0
    /// Whether the pointer has moved far enough to count as a drag. Until it
    /// has, a mouse-up is a click — and a click on an offered window takes it.
    private var didDrag = false

    var onSelectionSettled: ((CGRect) -> Void)?
    var onSelectionChanged: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onSave: (() -> Void)?
    /// A press outside the region threw it away and started another.
    var onSelectionRestarted: (() -> Void)?
    /// Raised whenever the pointer moves while choosing, for the loupe.
    var onPointerMoved: ((CGPoint) -> Void)?
    /// "C" while picking: the colour under the crosshair, as the loupe reports
    /// it, onto the clipboard.
    var onCopyColor: (() -> Void)?

    private var backdrop: NSImage?
    private weak var overlay: ShotOverlayView?
    /// The whole screen, blurred into blocks, drawn through the frame of every
    /// pixelate element. Made once and only if asked for: it costs a full-screen
    /// Core Image pass, and most shots never use the tool.
    private lazy var mosaic: NSImage? = makeMosaic()

    // Gesture state
    private var anchor: CGPoint?
    private var draft: ShotElement?
    private var movingID: UUID?
    private var moveOrigin: CGRect?
    private var movePoints: [CGPoint] = []
    /// Where a directed element's two ends were when the drag began. Kept
    /// alongside the frame because that is where an arrow actually lives: a
    /// move that only offsets the frame moves the selection outline and leaves
    /// the arrow behind it, drawn from the ends nobody touched.
    private var moveEnds: (start: CGPoint, end: CGPoint)?
    private var resizingHandle: Handle?
    private var selectionAnchor: CGRect?
    /// Set while the whole crop is being dragged around, which the Move tool
    /// does when the press lands on the region rather than on anything drawn
    /// in it. Re-cropping by eye is a matter of nudging the box, and nudging
    /// it used to mean grabbing an edge handle and then the opposite one.
    private var movingSelection = false
    private var editor: NSTextView?

    /// The grips. Eight around a box, and exactly two on an arrow or a line —
    /// its tail and its head, which are the only things about it worth
    /// adjusting and the two a box's corners cannot express.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case lineStart, lineEnd

        /// Grips that belong to a box. `allCases` includes the two line ends,
        /// which have no meaning on a rectangle.
        static let box: [Handle] = [
            .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left,
        ]
        static let line: [Handle] = [.lineStart, .lineEnd]

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .top: return CGPoint(x: rect.midX, y: rect.maxY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            // Meaningless on a bare rectangle; asked for only via `point(in:)`
            // below, which routes a directed element to its own ends.
            case .lineStart: return rect.origin
            case .lineEnd: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        /// The grip's position on an actual element, which is the only place
        /// that knows whether it is a box or a pair of ends.
        func point(in element: ShotElement) -> CGPoint {
            switch self {
            case .lineStart: return element.start
            case .lineEnd: return element.end
            default: return point(in: element.bounds)
            }
        }

        static func all(for element: ShotElement) -> [Handle] {
            element.isDirected ? line : box
        }

        /// Moves the edges this grip owns and leaves the others where they are.
        func resize(_ rect: CGRect, to point: CGPoint) -> CGRect {
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            switch self {
            case .topLeft: minX = point.x; maxY = point.y
            case .top: maxY = point.y
            case .topRight: maxX = point.x; maxY = point.y
            case .right: maxX = point.x
            case .bottomRight: maxX = point.x; minY = point.y
            case .bottom: minY = point.y
            case .bottomLeft: minX = point.x; minY = point.y
            case .left: minX = point.x
            // Handled by moving the element's own ends, not by reshaping a
            // box — see `resize(_:with:to:)`.
            case .lineStart, .lineEnd: break
            }
            return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY))
        }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func install(frame capture: ScreenCapture.Frame, document: ShotDocument) {
        self.frame_ = capture
        self.document = document
        backdrop = NSImage(cgImage: capture.image, size: capture.screen.frame.size)

        // The frozen screen becomes this view's layer contents, and is never
        // drawn again.
        //
        // This is the difference between an editor that keeps up and one that
        // does not. Every mouse move while dragging invalidates the view, and
        // blitting a full-screen Retina bitmap on the CPU each time costs tens
        // of milliseconds — unnoticeable on an idle machine, and ruinous the
        // moment something else is already reading the screen. Under a screen
        // recorder it was unusable. Handed to the compositor once, the picture
        // costs nothing to keep on screen, and a repaint costs only what is
        // painted over it.
        //
        // Everything painted over it lives in `overlay`, because a layer-backed
        // view's own drawing goes *underneath* its sublayers — so the picture
        // could not simply be a sublayer here; it would cover the very thing it
        // is a backdrop for.
        wantsLayer = true
        layer?.contents = capture.image
        layer?.contentsGravity = .resize

        let overlay = ShotOverlayView(frame: bounds)
        overlay.canvas = self
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .below, relativeTo: nil)
        self.overlay = overlay
        windows = capture.windows.map {
            $0.offsetBy(dx: -capture.screen.frame.minX, dy: -capture.screen.frame.minY)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    /// The chosen region in global screen coordinates — what the cropper wants.
    var selectionOnScreen: CGRect {
        guard let screen = frame_?.screen else { return .zero }
        return selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    // MARK: - Drawing

    /// A white blink over the region that was just taken.
    ///
    /// Short, and over the crop only. A full-screen flash is what phone cameras
    /// do and it is far too much for a desktop, where a shot is usually a
    /// corner of one window; blinking exactly the rectangle that was taken says
    /// *which* rectangle, which is the part worth confirming.
    func flashSelection() {
        guard !selection.isEmpty else { return }
        let flash = CALayer()
        flash.frame = selection
        flash.backgroundColor = NSColor.white.cgColor
        flash.cornerRadius = cornerRadius
        flash.opacity = 0
        // Added to the view's own layer, which puts it above both the picture
        // and the overlay — the one place a sublayer is what is wanted here.
        layer?.addSublayer(flash)

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.6
        animation.toValue = 0
        animation.duration = 0.22
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(animation, forKey: "flash")
    }

    /// Repaints one region rather than the whole screen. The margin covers the
    /// grips, the border and the size badge, all of which sit outside the
    /// rectangle they belong to.
    private func invalidate(_ rect: CGRect) {
        setNeedsDisplay(rect.insetBy(dx: -48, dy: -48))
    }

    /// Every `needsDisplay` in this file means "repaint what is drawn over the
    /// picture", and that is the overlay's job now.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        overlay?.setNeedsDisplay(invalidRect)
    }

    func drawOverlay(_ dirtyRect: NSRect) {
        // The picture itself is the layer underneath — see `install`. What is
        // painted here is only what changes: the dimming, the grid, the offer,
        // the crop's frame and whatever has been drawn on it.

        // Everything outside the chosen region goes under a wash. While
        // choosing it is heavier — the point then is to show what is being
        // picked out; once picked, the surroundings are context and a lighter
        // wash keeps them readable.
        let dim = phase == .choosing ? 0.45 : 0.55
        NSColor.black.withAlphaComponent(dim).setFill()
        if selection.isEmpty {
            // The offered window is left exactly as it is — not lifted, not
            // tinted, just not dimmed. Anything else changes the colours of
            // the thing being judged, which is the one thing a screenshot tool
            // must not do while somebody is choosing what to shoot.
            if let target = snapTarget {
                let radius = snapCornerRadius
                let path = NSBezierPath(rect: bounds)
                path.append(NSBezierPath(roundedRect: target, xRadius: radius, yRadius: radius))
                path.windingRule = .evenOdd
                path.fill()
            } else {
                bounds.fill()
            }
        } else {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(roundedRect: selection, xRadius: cornerRadius, yRadius: cornerRadius))
            path.windingRule = .evenOdd
            path.fill()
        }

        // A grid while picking, over the dimmed part only. Faint enough to be
        // scenery and regular enough to line an edge up against — which is the
        // whole job: a screenshot cropped by eye is nearly always a few pixels
        // out, and there is nothing on a dimmed desktop to measure against.
        if phase == .choosing {
            drawGrid()
            drawSnapTarget()
        }

        guard !selection.isEmpty else { return }

        // Annotations are clipped to the region: a stroke that wandered outside
        // would not survive the crop anyway, and showing it there promises
        // something the saved picture will not keep.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        for element in document?.elements ?? [] {
            draw(element)
        }
        if let draft { draw(draft) }
        NSGraphicsContext.restoreGraphicsState()

        drawSelectionFrame()

        if let selected = document?.element(document?.selection) {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let outline = NSBezierPath(
                roundedRect: selected.bounds.insetBy(dx: -5, dy: -5),
                xRadius: 4, yRadius: 4
            )
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.stroke()
            for handle in Handle.all(for: selected) {
                grip(at: handle.point(in: selected), radius: 4)
            }
        }
    }

    /// The chosen region's own outline.
    ///
    /// A hairline in white rather than a heavy accent-coloured box: the border
    /// is there to say where the crop ends, and anything thicker starts
    /// competing with what is inside it. The grips are pills — long on the
    /// edges, square at the corners — which is both easier to aim at than a dot
    /// and honest about what each one does.
    private func drawSelectionFrame() {
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let shadow = NSBezierPath(
            roundedRect: selection.insetBy(dx: -1, dy: -1),
            xRadius: cornerRadius, yRadius: cornerRadius
        )
        shadow.lineWidth = 1
        shadow.stroke()

        // Solid blue, and blue on purpose: the dashed blue means "this is what
        // a click would take", and the settled crop is no longer a proposal.
        // White was neither — invisible on a pale screenshot and unrelated to
        // anything else the editor draws.
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: selection, xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1.5
        border.stroke()

        guard phase == .choosing || document?.selection == nil else { return }
        for handle in Handle.box {
            pill(at: handle.point(in: selection), handle: handle)
        }
        drawSizeBadge()
    }

    /// How big the crop is, next to the corner it grew from. The number is the
    /// one thing about a selection that cannot be judged by looking at it.
    private func drawSizeBadge() {
        guard selection.width > 1 else { return }
        let text = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        // Inside the region when there is no room above it, which is what
        // happens the moment a selection touches the top of the screen.
        if origin.y + size.height + padding > bounds.maxY {
            origin.y = selection.maxY - size.height - padding * 2 - 6
        }
        let box = CGRect(
            x: origin.x, y: origin.y,
            width: size.width + padding * 2, height: size.height + padding
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(
            at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attributes
        )
    }

    private func pill(at point: CGPoint, handle: Handle) {
        let long: CGFloat = 14
        let short: CGFloat = 4
        var size = CGSize(width: short, height: short)
        switch handle {
        case .top, .bottom: size = CGSize(width: long, height: short)
        case .left, .right: size = CGSize(width: short, height: long)
        default: size = CGSize(width: 7, height: 7)
        }
        let rect = CGRect(
            x: point.x - size.width / 2, y: point.y - size.height / 2,
            width: size.width, height: size.height
        )
        let radius = min(size.width, size.height) / 2
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: -1), xRadius: radius, yRadius: radius).fill()
        let pill = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        pill.fill()
        // A blue rim ties the grips to the border they sit on, and keeps them
        // from vanishing into a white screenshot.
        NSColor.controlAccentColor.setStroke()
        pill.lineWidth = 1
        pill.stroke()
    }

    /// The window the pointer is over, offered for one click.
    ///
    /// Lit back to its own brightness, and then outlined in a dashed blue.
    /// The lighting alone was the first attempt and it failed on the commonest
    /// case there is: a white window on a white background, where "slightly
    /// less dimmed" is no edge at all. A dashed line is visible against any
    /// colour, and blue says it is a proposal rather than part of the picture.
    private func drawSnapTarget() {
        guard selection.isEmpty, let target = snapTarget else { return }
        let radius = snapCornerRadius
        let path = NSBezierPath(roundedRect: target, xRadius: radius, yRadius: radius)

        // A dark hairline under the dashes, so the blue holds its own over a
        // pale window as well as a dark one.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let shadow = NSBezierPath(
            roundedRect: target.insetBy(dx: -1, dy: -1),
            xRadius: radius + 1, yRadius: radius + 1
        )
        shadow.lineWidth = 1
        shadow.stroke()

        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.setLineDash([7, 4], count: 2, phase: 0)
        path.stroke()
    }

    /// What macOS rounds its window corners by. Not readable from anywhere, so
    /// it is measured once and written down; being a point or two out is
    /// invisible against the window's own shadow.
    static let windowCornerRadius: CGFloat = 10

    private func drawGrid() {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Clipped out of whatever is currently un-dimmed, so the area that
        // would be captured stays untouched.
        if let hole = selection.isEmpty ? snapTarget : selection {
            let radius = selection.isEmpty ? snapCornerRadius : cornerRadius
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(roundedRect: hole, xRadius: radius, yRadius: radius))
            path.windingRule = .evenOdd
            path.addClip()
        }

        let step: CGFloat = 40
        NSColor.white.withAlphaComponent(0.07).setStroke()
        let path = NSBezierPath()
        var x = step
        while x < bounds.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: bounds.height))
            x += step
        }
        var y = step
        while y < bounds.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: bounds.width, y: y))
            y += step
        }
        path.lineWidth = 1
        path.stroke()
    }

    private func grip(at point: CGPoint, radius: CGFloat = 4) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        path.lineWidth = 1
        path.stroke()
    }

    private func draw(_ element: ShotElement) {
        let color = element.color
        let rect = element.bounds

        switch element.tool {
        case .rectangle:
            color.setStroke()
            // Rounded, and by a share of the shape rather than a fixed number,
            // so a small box does not come out as a lozenge and a large one
            // still reads as rounded.
            let radius = min(12, min(rect.width, rect.height) / 4)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = element.lineWidth
            path.stroke()
        case .ellipse:
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = element.lineWidth
            path.stroke()
        case .line:
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: element.start)
            path.line(to: element.end)
            path.lineWidth = element.lineWidth
            path.lineCapStyle = .round
            path.stroke()
        case .arrow:
            color.setFill()
            arrowPath(from: element.start, to: element.end, width: element.lineWidth).fill()
        case .pen:
            color.setStroke()
            strokePath(element.points, width: element.lineWidth).stroke()
        case .highlighter:
            // Multiply, so what is underneath still reads through the colour —
            // that is the difference between a highlighter and a paint stripe.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .multiply
            color.withAlphaComponent(0.4).setStroke()
            strokePath(element.points, width: max(element.lineWidth * 5, 14)).stroke()
            NSGraphicsContext.restoreGraphicsState()
        case .pixelate:
            guard let mosaic else { break }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            mosaic.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
        case .text:
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: element.lineWidth * 6, weight: .semibold),
                .foregroundColor: color,
            ]
            (element.text as NSString).draw(
                in: rect.insetBy(dx: 2, dy: 2),
                withAttributes: attributes
            )
        case .select:
            break
        }
    }

    private func strokePath(_ points: [CGPoint], width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    /// A filled arrow rather than a stroked line with a V on the end: the head
    /// then scales with the shaft and stays an arrow at any size.
    ///
    /// The shaft tapers — a point at the tail, full width where the head
    /// begins. A parallel-sided stick with a triangle stuck on the end is what
    /// every drawing tool draws, and it reads as a diagram; the taper is what
    /// makes it read as a pointer.
    private func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> NSBezierPath {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = hypot(end.x - start.x, end.y - start.y)
        let head = min(max(width * 4, 10), max(length * 0.5, 1))
        let half = width * 0.7
        let shoulder = length - head
        // The tail keeps most of its width rather than tapering to nothing.
        // A shaft that starts at a point looks like it was drawn with a dying
        // pen; the taper should say "this end, not that one", not "this end
        // is missing".
        let tail = half * 0.55

        let path = NSBezierPath()
        // Rounded off across the tail, down one side, out to the barb, across
        // the tip, and back up the other side.
        path.move(to: CGPoint(x: tail * 0.6, y: -tail))
        path.curve(
            to: CGPoint(x: tail * 0.6, y: tail),
            controlPoint1: CGPoint(x: -tail * 0.5, y: -tail),
            controlPoint2: CGPoint(x: -tail * 0.5, y: tail)
        )
        path.curve(
            to: CGPoint(x: shoulder, y: half),
            controlPoint1: CGPoint(x: shoulder * 0.55, y: tail * 1.05),
            controlPoint2: CGPoint(x: shoulder * 0.82, y: half * 0.9)
        )
        path.line(to: CGPoint(x: shoulder, y: head * 0.55))
        path.line(to: CGPoint(x: length, y: 0))
        path.line(to: CGPoint(x: shoulder, y: -head * 0.55))
        path.line(to: CGPoint(x: shoulder, y: -half))
        path.curve(
            to: CGPoint(x: tail * 0.6, y: -tail),
            controlPoint1: CGPoint(x: shoulder * 0.82, y: -half * 0.9),
            controlPoint2: CGPoint(x: shoulder * 0.55, y: -tail * 1.05)
        )
        path.close()

        var transform = AffineTransform(translationByX: start.x, byY: start.y)
        transform.rotate(byRadians: angle)
        path.transform(using: transform)
        return path
    }

    private func makeMosaic() -> NSImage? {
        guard let capture = frame_ else { return nil }
        let input = CIImage(cgImage: capture.image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(capture.image.width, capture.image.height) / 90, forKey: kCIInputScaleKey)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: capture.screen.frame.size)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onPointerMoved?(point)
        guard phase == .choosing, selection.isEmpty else { return }

        let target: CGRect?
        let radius: CGFloat
        if menuBarStrip.contains(point) {
            // The menu bar belongs to no window and to every window. Pointing
            // at it means "all of this", which is the one region nobody wants
            // to drag out by hand across a whole display.
            target = bounds
            radius = 0
        } else {
            // Front to back, so the window on top wins — the same one a click
            // would have landed in.
            target = windows.first { $0.contains(point) }
            radius = Self.windowCornerRadius
        }

        if target != snapTarget {
            snapTarget = target
            snapCornerRadius = radius
            needsDisplay = true
        }
    }

    /// The strip the menu bar occupies, in view coordinates. Measured rather
    /// than assumed: it is taller on a Mac with a notch, and zero when the bar
    /// auto-hides.
    private var menuBarStrip: CGRect {
        guard let screen = frame_?.screen else { return .zero }
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return CGRect(x: 0, y: bounds.maxY - height, width: bounds.width, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        commitEditor()
        let point = convert(event.locationInWindow, from: nil)

        if phase == .choosing {
            anchor = point
            didDrag = false
            selection = CGRect(origin: point, size: .zero)
            needsDisplay = true
            return
        }

        guard let document else { return }

        // The chosen region's own grips win over everything: they sit on its
        // edge, which is exactly where a rectangle drawn around the whole
        // region also sits, and being unable to re-crop is worse than having
        // to move an arrow off the edge first.
        if let handle = handle(near: point, in: selection) {
            resizingHandle = handle
            selectionAnchor = selection
            return
        }

        // Before the tools get a say, and deliberately: a press outside the
        // region means the same thing whichever tool is chosen, and the
        // pointer's own branch used to return before ever reaching this — so
        // with the pointer as the starting tool, which it now is, re-cropping
        // by clicking elsewhere never happened at all.
        if !selection.contains(point) {
            document.selection = nil
            phase = .choosing
            anchor = point
            didDrag = false
            cornerRadius = 0
            selection = CGRect(origin: point, size: .zero)
            onSelectionRestarted?()
            needsDisplay = true
            return
        }

        // Whatever the tool, the *selected* element answers first. Drawing a
        // shape selects it, and a selection one cannot grab is a selection
        // that means nothing: the handles are right there and the obvious next
        // move — nudge it, stretch it — used to start drawing a second shape
        // on top instead. Only the selected one behaves this way, so a tool
        // still draws freely everywhere else.
        if let selected = document.element(document.selection) {
            if let handle = handle(near: point, in: selected, radius: 8) {
                document.beginGesture()
                document.adoptStyle(of: selected)
                resizingHandle = handle
                movingID = selected.id
                moveOrigin = selected.frame
                movePoints = selected.points
                moveEnds = (selected.start, selected.end)
                return
            }
            if selected.hits(point) {
                document.beginGesture()
                document.adoptStyle(of: selected)
                movingID = selected.id
                moveOrigin = selected.frame
                movePoints = selected.points
                moveEnds = (selected.start, selected.end)
                anchor = point
                return
            }
        }

        if document.tool == .select {
            if document.hitTest(point) == nil {
                // Nothing drawn under the pointer, and the press is inside the
                // region: take the region itself.
                document.selection = nil
                movingSelection = true
                selectionAnchor = selection
                anchor = point
                needsDisplay = true
                return
            }
            if let hit = document.hitTest(point) {
                document.selection = hit.id
                document.adoptStyle(of: hit)
                document.beginGesture()
                movingID = hit.id
                moveOrigin = hit.frame
                movePoints = hit.points
                moveEnds = (hit.start, hit.end)
                anchor = point
            } else {
                document.selection = nil
            }
            needsDisplay = true
            return
        }

        if document.tool == .text {
            beginTextEditing(at: point)
            return
        }

        anchor = point
        var element = ShotElement(
            tool: document.tool,
            frame: CGRect(origin: point, size: .zero),
            color: document.color,
            lineWidth: document.lineWidth
        )
        element.start = point
        element.end = point
        if !document.tool.isDragged { element.points = [point] }
        draft = element
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if phase == .choosing, let anchor {
            if hypot(point.x - anchor.x, point.y - anchor.y) > 3 { didDrag = true }
            cornerRadius = 0
            snapTarget = nil
            let previous = selection
            selection = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            )
            onSelectionChanged?(selection)
            onPointerMoved?(point)
            // Only the band that changed. Everything this view paints is
            // clipped to the invalid rectangle anyway, so narrowing it turns a
            // full-screen repaint per mouse event into a repaint of the strip
            // the edge swept across — which is the difference between smooth
            // and not on a machine that is already busy sending the screen
            // somewhere else.
            invalidate(previous.union(selection))
            return
        }

        if movingSelection, let selectionAnchor, let anchor {
            let previous = selection
            let delta = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
            var moved = selectionAnchor.offsetBy(dx: delta.width, dy: delta.height)
            // Kept on the display: a crop dragged off the edge would come back
            // as a band of nothing.
            moved.origin.x = max(0, min(moved.origin.x, bounds.maxX - moved.width))
            moved.origin.y = max(0, min(moved.origin.y, bounds.maxY - moved.height))
            selection = moved
            onSelectionChanged?(selection)
            invalidate(previous.union(selection))
            return
        }

        if let handle = resizingHandle {
            if let movingID, var element = document?.element(movingID) {
                switch handle {
                case .lineStart: element.start = point
                case .lineEnd: element.end = point
                default: element.frame = handle.resize(element.bounds, to: point)
                }
                document?.update(element)
            } else if let anchorRect = selectionAnchor {
                selection = handle.resize(anchorRect, to: point).intersection(bounds)
                onSelectionChanged?(selection)
            }
            needsDisplay = true
            return
        }

        if let movingID, let moveOrigin, let anchor, var element = document?.element(movingID) {
            let delta = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
            element.frame = moveOrigin.offsetBy(dx: delta.width, dy: delta.height)
            element.points = movePoints.map {
                CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
            }
            if let moveEnds {
                element.start = CGPoint(x: moveEnds.start.x + delta.width, y: moveEnds.start.y + delta.height)
                element.end = CGPoint(x: moveEnds.end.x + delta.width, y: moveEnds.end.y + delta.height)
            }
            document?.update(element)
            needsDisplay = true
            return
        }

        guard var element = draft, let anchor else { return }
        if element.tool.isDragged {
            // Measured from where the mouse went down, which is held in
            // `anchor` and never touched again. Reading the anchor back off
            // the shape — as this used to — loses it the moment the shape is
            // rewritten: drag downwards and the shape's own origin became the
            // pointer's latest position, so the next event measured from
            // there, and the box ran away down the screen instead of growing.
            if element.isDirected {
                element.start = anchor
                element.end = point
            } else {
                element.frame = CGRect(
                    x: min(anchor.x, point.x),
                    y: min(anchor.y, point.y),
                    width: abs(point.x - anchor.x),
                    height: abs(point.y - anchor.y)
                )
            }
        } else {
            element.points.append(point)
            element.frame = boundingBox(element.points)
        }
        draft = element
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil
            movingID = nil
            moveOrigin = nil
            movePoints = []
            moveEnds = nil
            resizingHandle = nil
            selectionAnchor = nil
            movingSelection = false
            needsDisplay = true
        }

        if phase == .choosing {
            // A click rather than a drag: if a window was being offered, that
            // is what was clicked, and taking it is the whole point of the
            // offer. Otherwise it was a mis-click, not a zero-sized crop.
            if !didDrag, let target = snapTarget {
                selection = target.intersection(bounds)
                cornerRadius = snapCornerRadius
                snapTarget = nil
                phase = .editing
                onSelectionSettled?(selection)
                return
            }
            guard selection.width > 8, selection.height > 8 else {
                selection = .zero
                return
            }
            phase = .editing
            onSelectionSettled?(selection)
            return
        }

        if let element = draft {
            draft = nil
            let big = element.tool.isDragged
                ? (element.bounds.width > 4 || element.bounds.height > 4)
                : element.points.count > 1
            guard big else { return }
            document?.add(element)
        }
    }

    private func handle(near point: CGPoint, in rect: CGRect, radius: CGFloat = 8) -> Handle? {
        guard !rect.isEmpty else { return nil }
        return Handle.box.first { handle in
            let grip = handle.point(in: rect)
            return hypot(grip.x - point.x, grip.y - point.y) <= radius
        }
    }

    /// The element's own grips — two on an arrow, eight on a box.
    private func handle(near point: CGPoint, in element: ShotElement, radius: CGFloat = 8) -> Handle? {
        Handle.all(for: element).first { handle in
            let grip = handle.point(in: element)
            return hypot(grip.x - point.x, grip.y - point.y) <= radius
        }
    }

    private func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            rect = rect.union(CGRect(origin: point, size: .zero))
        }
        return rect
    }

    // MARK: - Text

    /// Typing happens in a real text view laid over the canvas, which is then
    /// thrown away and its string kept. Hand-rolling a caret, a selection and
    /// an input method — the last one is not optional for anyone typing
    /// Japanese — to draw text into a canvas is the kind of work `NSTextView`
    /// already did.
    private func beginTextEditing(at point: CGPoint) {
        guard let document else { return }
        let font = NSFont.systemFont(ofSize: document.lineWidth * 6, weight: .semibold)
        // Tall enough for the type it is set in, and hung *below* the click.
        // This view counts upwards from the bottom, so a frame placed at the
        // press grew away from it — the field appeared above the pointer and
        // the first letter landed nowhere near where it was asked for.
        let height = max(font.ascender - font.descender + 8, 22)
        let size = CGSize(
            width: max(min(320, selection.maxX - point.x), 120),
            height: height
        )
        let view = NSTextView(frame: CGRect(
            origin: CGPoint(x: point.x, y: point.y - height),
            size: size
        ))
        view.font = font
        view.textColor = document.color
        view.backgroundColor = .black.withAlphaComponent(0.25)
        view.isRichText = false
        view.drawsBackground = true
        addSubview(view)
        window?.makeFirstResponder(view)
        editor = view
    }

    /// Turns whatever is in the editor into an element, or drops it if empty.
    func commitEditor() {
        guard let editor, let document else { return }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = editor.frame
        editor.removeFromSuperview()
        self.editor = nil
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: document.lineWidth * 6, weight: .semibold)
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        var element = ShotElement(
            tool: .text,
            frame: CGRect(origin: frame.origin,
                          size: CGSize(width: measured.width + 6, height: measured.height + 4)),
            color: document.color,
            lineWidth: document.lineWidth
        )
        element.text = text
        document.add(element)
        needsDisplay = true
    }

    var isEditingText: Bool { editor != nil }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // esc
            // One press leaves the text field, a second closes the shot. And
            // what was typed is kept: Esc conventionally throws a field's
            // contents away, but here the field is a thing being placed on a
            // picture, and losing a sentence to a stray keypress is worse than
            // having to undo one.
            if isEditingText {
                commitEditor()
            } else {
                onCancel?()
            }
        case 36, 76: // return
            if isEditingText { commitEditor() } else { onConfirm?() }
        case 51, 117: // delete
            document?.removeSelected()
            needsDisplay = true
        case 6 where flags == .command: // ⌘Z
            document?.undo()
            needsDisplay = true
        case 6 where flags == [.command, .shift]: // ⇧⌘Z
            document?.redo()
            needsDisplay = true
        case 8 where phase == .choosing && flags.isEmpty: // C, while picking
            onCopyColor?()
        // The shortcut everyone tries first. ⏎ has always done this, but
        // nobody reaches for ⏎ to copy something.
        case 8 where flags == .command: // ⌘C
            onConfirm?()
        case 1 where flags == .command: // ⌘S
            onSave?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Redrawn from the outside whenever the toolbar changes something the
    /// canvas shows — the colour, the tool, an undo.
    ///
    /// The text being typed is restyled here too. It is an `NSTextView` rather
    /// than something this view draws, so a repaint alone leaves it in the size
    /// and colour it was created with — the change would only appear once
    /// typing finished and the string became an element, which is exactly when
    /// it is too late to judge it.
    func refresh() {
        if let editor, let document {
            editor.font = .systemFont(ofSize: document.lineWidth * 6, weight: .semibold)
            editor.textColor = document.color
        }
        needsDisplay = true
    }

    /// Paints the annotations and nothing else, into whatever context is
    /// current. This is what goes into the saved picture: no dimming, no
    /// selection outline, no handles — those belong to the editor, not to the
    /// screenshot somebody is about to send.
    func drawElements() {
        for element in document?.elements ?? [] {
            draw(element)
        }
    }
}
