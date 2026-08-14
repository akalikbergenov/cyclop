import AppKit
import Combine
import SwiftUI

/// Taking a screenshot, from the shortcut to what is left on the clipboard.
///
/// The sequence is: freeze every display, cover every display with the frozen
/// picture, let the user pick a region on one of them, then turn that display's
/// overlay into an editor and put the others away. Everything after that —
/// drawing, moving, reading text, translating it — happens on the one overlay
/// that is left.
@MainActor
final class ShotController {
    private var panels: [ShotPanel] = []
    private var canvas: ShotCanvasView?
    private var loupe: ShotLoupeView?
    private var toolbar: NSHostingView<ShotToolbarView>?
    private var textWindow: ShotTextWindow?
    private var document = ShotDocument()
    private var translator = Translator()
    private var activeFrame: ScreenCapture.Frame?
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var isRecognising = false
    /// Whether a region has already been settled once in this shot. Picking a
    /// new one runs `settle` again, and the parts that are true only of a first
    /// crop — the starting tool, the subscription — must not be redone.
    private var hasSettled = false

    private let settings = Settings.shared

    var isActive: Bool { !panels.isEmpty }

    // MARK: - Shortcut

    func installHotKey() {
        apply(settings.shotHotKey)
        // The *delivered* value, not the property.
        //
        // `@Published` announces a change from `willSet` — before the property
        // holds the new value — so a handler that reads the property back gets
        // the old one and dutifully re-registers the shortcut that was just
        // replaced. That is why a newly recorded combination only started
        // working after a restart, or after something else happened to
        // re-register it.
        settings.$shotHotKey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] combo in
                MainActor.assumeIsolated { self?.apply(combo) }
            }
            .store(in: &cancellables)
    }

    func teardown() {
        hotKey?.unregister()
        hotKey = nil
        dismiss()
    }

    private func apply(_ combo: HotKeyCombo?) {
        hotKey?.unregister()
        hotKey = nil
        guard let combo else { return }
        hotKey = HotKey(combo: combo) { [weak self] in
            self?.begin()
        }
        if hotKey == nil {
            NSLog("Cyclop: \(combo.label) is already registered by another application")
        }
    }

    // MARK: - Beginning

    func begin() {
        guard !isActive else { return }

        // Screen contents are the one thing macOS will not hand over on a
        // promise. Asked for here, at the moment somebody pressed the shortcut
        // for a screenshot, rather than at launch where it would be a mystery.
        guard ScreenCapture.isPermitted else {
            ScreenCapture.requestPermission()
            ScreenCapture.openSettings()
            return
        }

        Task {
            do {
                let frames = try await ScreenCapture.frames()
                guard !frames.isEmpty else { return }
                present(frames)
            } catch {
                NSLog("Cyclop: screen capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func present(_ frames: [ScreenCapture.Frame]) {
        document = ShotDocument()
        translator = Translator()
        isRecognising = false
        hasSettled = false

        for frame in frames {
            let panel = ShotPanel(screen: frame.screen)
            panel.onCancel = { [weak self] in self?.dismiss() }

            let canvas = ShotCanvasView(frame: CGRect(origin: .zero, size: frame.screen.frame.size))
            canvas.autoresizingMask = [.width, .height]
            canvas.install(frame: frame, document: document)
            canvas.onCancel = { [weak self] in self?.dismiss() }
            canvas.onConfirm = { [weak self] in self?.copyAndClose() }
            canvas.onSave = { [weak self] in self?.saveAndClose() }
            canvas.onSelectionRestarted = { [weak self] in
                // The tools belong to a settled region; picking a new one puts
                // them away until it is settled again.
                self?.toolbar?.removeFromSuperview()
                self?.toolbar = nil
                self?.textWindow?.close()
                self?.textWindow = nil
            }
            canvas.onSelectionSettled = { [weak self] _ in
                self?.settle(on: frame, canvas: canvas, panel: panel)
            }
            canvas.onSelectionChanged = { [weak self] rect in
                self?.layoutChrome(for: rect)
            }
            canvas.onPointerMoved = { [weak self] point in
                self?.moveLoupe(to: point, canvas: canvas)
            }
            canvas.onCopyColor = { [weak self] in
                guard let hex = self?.loupe?.colorHex else { return }
                self?.copyText(hex)
            }

            panel.contentView = canvas
            panel.orderFrontRegardless()
            panels.append(panel)

            // The loupe belongs to whichever display the pointer is on; made
            // for each, shown by the first pointer movement.
            let loupe = ShotLoupeView(frame: CGRect(x: 0, y: 0, width: 96, height: 140))
            loupe.frame_ = frame
            loupe.isHidden = true
            canvas.addSubview(loupe)
            if frame.screen.frame.contains(NSEvent.mouseLocation) {
                self.loupe = loupe
                self.activeFrame = frame
                self.canvas = canvas
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(canvas)
            }
        }

        // A shot is a mode: the app comes forward for as long as one is open,
        // so the keyboard is unambiguously the editor's.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The region is chosen. Everything that is not this display goes away, and
    /// the tools appear.
    private func settle(on frame: ScreenCapture.Frame, canvas: ShotCanvasView, panel: ShotPanel) {
        activeFrame = frame
        self.canvas = canvas
        loupe?.isHidden = true

        for other in panels where other !== panel {
            other.orderOut(nil)
        }
        panels = [panel]
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)

        if !hasSettled {
            hasSettled = true
            // The pointer, not a shape. Landing in a drawing tool means the
            // first click after cropping draws a rectangle nobody asked for —
            // and the first thing most people do with a fresh crop is look at
            // it. Only on the first crop: re-cropping must not throw away the
            // tool the user had chosen.
            document.tool = .select

            // The canvas paints from the document, and the document is changed
            // by SwiftUI buttons that know nothing about it.
            document.objectWillChange
                .sink { [weak canvas] in
                    DispatchQueue.main.async { canvas?.refresh() }
                }
                .store(in: &cancellables)
        }

        let toolbar = NSHostingView(rootView: makeToolbar())
        toolbar.layer?.backgroundColor = .clear
        canvas.addSubview(toolbar)
        self.toolbar = toolbar

        layoutChrome(for: canvas.selection)
    }

    private func makeToolbar() -> ShotToolbarView {
        ShotToolbarView(
            document: document,
            isBusy: isRecognising,
            onRecognize: { [weak self] in self?.recognise() },
            onCopy: { [weak self] in self?.copyAndClose() },
            onSave: { [weak self] in self?.saveAndClose() },
            onCancel: { [weak self] in self?.dismiss() }
        )
    }

    /// Puts the toolbar under the region, or above it when there is no room —
    /// and inside the screen either way. A toolbar half off the bottom of the
    /// display is a toolbar with the Copy button missing.
    private func layoutChrome(for selection: CGRect) {
        guard let canvas, let toolbar else { return }
        let size = toolbar.fittingSize
        // The menu bar's height, which on a notched Mac is also the notch's:
        // nothing may be placed in that strip, because the camera housing sits
        // in the middle of it and would swallow the middle of the toolbar.
        let forbiddenTop = max(
            canvas.frame_.map { $0.screen.frame.maxY - $0.screen.visibleFrame.maxY } ?? 24,
            24
        )
        let topLimit = canvas.bounds.maxY - forbiddenTop - size.height - 10

        var origin = CGPoint(
            x: selection.midX - size.width / 2,
            y: selection.minY - size.height - 10
        )
        if origin.y < 10 {
            // No room underneath. Above it, if that is clear of the notch;
            // otherwise inside the region along its bottom edge, which is the
            // one place that always exists — a selection of the whole screen
            // has no outside at all, and that is exactly when the toolbar used
            // to end up half-hidden behind the camera.
            let above = selection.maxY + 10
            origin.y = above <= topLimit ? above : selection.minY + 12
        }
        origin.y = max(10, min(origin.y, topLimit))
        origin.x = max(10, min(origin.x, canvas.bounds.maxX - size.width - 10))
        toolbar.frame = CGRect(origin: origin, size: size)

    }

    private func moveLoupe(to point: CGPoint, canvas: ShotCanvasView) {
        guard canvas.phase == .choosing,
              let loupe = canvas.subviews.compactMap({ $0 as? ShotLoupeView }).first else { return }
        self.loupe = loupe
        loupe.isHidden = false
        loupe.point = point
        loupe.selectionSize = canvas.selection.size
        // Ahead and below the pointer, flipped near an edge so it is never
        // clipped and never covers what is about to be selected.
        var origin = CGPoint(x: point.x + 16, y: point.y - loupe.frame.height - 16)
        if origin.x + loupe.frame.width > canvas.bounds.maxX { origin.x = point.x - loupe.frame.width - 16 }
        if origin.y < 0 { origin.y = point.y + 16 }
        loupe.setFrameOrigin(origin)
        loupe.needsDisplay = true
    }

    // MARK: - Results

    /// The chosen region, with everything drawn on it, as an image.
    private func render() -> CGImage? {
        guard let canvas, let frame = activeFrame else { return nil }
        canvas.commitEditor()

        let rect = canvas.selectionOnScreen
        guard let base = frame.crop(to: rect) else { return nil }
        guard !document.isEmpty || canvas.cornerRadius > 0 else { return base }

        // Drawn again into a bitmap at the picture's own resolution rather
        // than snapshotting the view: the view is dimmed, carries handles and
        // a selection outline, and none of that belongs in the file.
        let size = NSSize(width: base.width, height: base.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: base.width,
            pixelsHigh: base.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return base }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // A shot snapped to a window is rounded off the way the window is, so
        // the corners come out transparent instead of carrying four slices of
        // whatever was behind it.
        if canvas.cornerRadius > 0 {
            let radius = canvas.cornerRadius * frame.scale
            NSBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                xRadius: radius, yRadius: radius
            ).addClip()
        }
        NSImage(cgImage: base, size: size).draw(in: CGRect(origin: .zero, size: size))

        // Annotations were placed in canvas points relative to the whole
        // screen; the bitmap is the crop, in pixels.
        let context = NSGraphicsContext.current?.cgContext
        context?.translateBy(x: -canvas.selection.minX * frame.scale, y: -canvas.selection.minY * frame.scale)
        context?.scaleBy(x: frame.scale, y: frame.scale)
        canvas.drawElements()
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }

    /// Reads the region and opens the window that shows what it said.
    ///
    /// The reading itself lives in that window: the language it was read in is
    /// chosen there, and changing it re-reads the same picture. Running it here
    /// would mean a language menu on the shot toolbar for a result that is not
    /// on screen yet — which is where it was, and it was the wrong place.
    private func recognise() {
        guard let canvas, let frame = activeFrame, !isRecognising else { return }
        guard let image = frame.crop(to: canvas.selectionOnScreen) else { return }
        showText(image)
    }

    private func showText(_ image: CGImage) {
        textWindow?.close()

        // The window is made first and captured weakly by the view it holds,
        // which is a knot but the honest one: the height depends on what the
        // view is showing, and only the window can change it.
        var window: ShotTextWindow?
        let view = NSHostingView(rootView: ShotTextReader(
            translator: translator,
            settings: settings,
            image: image,
            onCopy: { [weak self] string in self?.copyText(string) },
            onTranslationVisible: { visible in
                window?.setTranslationVisible(visible)
            }
        ))
        window = ShotTextWindow(content: view)
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        textWindow = window
    }

    private func copyText(_ string: String) {
        guard !string.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Copy is the default ending: the picture goes on the clipboard, the
    /// buffer picks it up the way it picks up any copied image — saving it to
    /// disk if that is switched on — and the editor closes.
    private func copyAndClose() {
        guard let image = render() else { dismiss(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = png(from: image) {
            pasteboard.setData(png, forType: .png)
        }
        confirmAndDismiss()
    }

    /// Save writes the file itself and puts it in the buffer, without going
    /// through the clipboard — the difference is what somebody wanting to keep
    /// a shot without disturbing what they had copied is asking for.
    private func saveAndClose() {
        guard let image = render(), let png = png(from: image) else { dismiss(); return }
        if let url = ScreenshotVault.save(png) {
            BufferStore.shared.add([url])
        }
        confirmAndDismiss()
    }

    /// Says the shot was taken, then puts the editor away.
    ///
    /// The order matters: the blink has to be over the region while the region
    /// is still on screen, so the editor stays up for exactly as long as it
    /// lasts. Cancelling skips all of this — nothing happened, and nothing
    /// should be confirmed.
    private func confirmAndDismiss() {
        ShotSound.play()
        canvas?.flashSelection()
        // The toolbar goes at once: it is not part of the picture and has no
        // business being in the last thing the user sees of it.
        toolbar?.removeFromSuperview()
        toolbar = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.dismiss()
        }
    }

    private func png(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func refreshToolbar() {
        toolbar?.rootView = makeToolbar()
        if let canvas { layoutChrome(for: canvas.selection) }
    }

    func dismiss() {
        for panel in panels {
            panel.contentView = nil
            panel.orderOut(nil)
        }
        panels.removeAll()
        cancellables.removeAll()
        textWindow?.close()
        textWindow = nil
        canvas = nil
        loupe = nil
        toolbar = nil
        activeFrame = nil
        // The shortcut subscription went with the rest; put it back.
        installHotKey()
    }
}
