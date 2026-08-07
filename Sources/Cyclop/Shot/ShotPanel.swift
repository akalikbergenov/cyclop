import AppKit

/// One display's worth of overlay.
///
/// Unlike everything else in this app, this window *does* activate: the shot
/// editor is a mode — the screen is frozen, the pointer is a crosshair, and
/// every key belongs to the editor until it is dismissed. A panel that took
/// keys without activating would leave the app underneath looking focused
/// while typing went somewhere else, which is exactly the confusion the
/// non-activating panel exists to avoid everywhere else.
final class ShotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        appearance = NSAppearance(named: .darkAqua)
        isFloatingPanel = true
        // Above the notch panel and above the buffer list: while a shot is
        // being taken nothing else in this app has anything to say.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
        // The crosshair says "pick something" before any text does.
        contentView?.addCursorRect(screen.frame, cursor: .crosshair)
    }

    /// Esc arrives here whenever the canvas is not first responder — which is
    /// exactly the case while text is being typed, because the text view holds
    /// the keyboard. So the first press has to be offered to the editor: it
    /// leaves the field, and only a press with nothing left to leave closes
    /// the shot.
    override func cancelOperation(_ sender: Any?) {
        if let canvas = contentView as? ShotCanvasView, canvas.isEditingText {
            canvas.commitEditor()
            return
        }
        onCancel?()
    }

    var onCancel: (() -> Void)?
}

/// The little square that follows the pointer while a region is being chosen.
///
/// It shows what is under the crosshair magnified, the size of the selection
/// and the colour of the pixel — the three things one is squinting at anyway.
/// Copying the colour is what turns it from decoration into a tool.
final class ShotLoupeView: NSView {
    var frame_: ScreenCapture.Frame?
    var point: CGPoint = .zero
    var selectionSize: CGSize = .zero

    override var isFlipped: Bool { false }

    /// The hex under the crosshair, for the "press C" shortcut.
    private(set) var colorHex: String = "#000000"

    override func draw(_ dirtyRect: NSRect) {
        guard let capture = frame_ else { return }

        let scale = capture.scale
        let zoom: CGFloat = 8
        let side: CGFloat = 96
        let sample = side / zoom

        let source = CGRect(
            x: (point.x - sample / 2) * scale,
            y: (capture.screen.frame.height - point.y - sample / 2) * scale,
            width: sample * scale,
            height: sample * scale
        )

        let box = CGRect(x: 0, y: bounds.height - side, width: side, height: side)
        NSColor.black.setFill()
        box.fill()

        if let cropped = capture.image.cropping(to: source.integral) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: cropped, size: box.size).draw(in: box)
            colorHex = hex(of: cropped)
        }

        // Crosshair through the middle of the magnified square, so the pixel
        // being reported is the pixel being pointed at.
        NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: box.minX, y: box.midY))
        cross.line(to: CGPoint(x: box.maxX, y: box.midY))
        cross.move(to: CGPoint(x: box.midX, y: box.minY))
        cross.line(to: CGPoint(x: box.midX, y: box.maxY))
        cross.lineWidth = 1
        cross.stroke()

        NSColor.white.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(rect: box)
        border.lineWidth = 1
        border.stroke()

        let caption = """
        \(Int(selectionSize.width)) × \(Int(selectionSize.height))
        \(colorHex)
        \(localized("Press \"C\" to copy"))
        """
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let captionRect = CGRect(x: 0, y: 0, width: side, height: bounds.height - side - 2)
        NSColor.black.withAlphaComponent(0.85).setFill()
        captionRect.fill()
        (caption as NSString).draw(in: captionRect.insetBy(dx: 4, dy: 2), withAttributes: attributes)
    }

    private func hex(of image: CGImage) -> String {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return colorHex }
        // Middle pixel of the magnified crop — the one under the crosshair.
        let x = image.width / 2
        let y = image.height / 2
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        guard CFDataGetLength(data) > offset + 2 else { return colorHex }
        // BGRA is what ScreenCaptureKit hands back.
        let blue = pointer[offset]
        let green = pointer[offset + 1]
        let red = pointer[offset + 2]
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
