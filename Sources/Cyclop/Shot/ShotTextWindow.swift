import AppKit
import SwiftUI
import Translation

/// The window recognised text is read in.
///
/// A window rather than a card floating on the overlay, and that is the whole
/// point of it. The card sat on the canvas, so every press aimed at it that
/// missed by a few points landed on the canvas instead — which re-cropped the
/// shot and threw the text away. Reading, checking, translating and copying are
/// unhurried, fiddly work with the pointer, and doing them on a surface where a
/// near miss destroys the thing being read is a design that punishes aim.
final class ShotTextWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(content: NSView) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 380),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        appearance = NSAppearance(named: .darkAqua)
        // Empty, not merely hidden: `titleVisibility` still leaves the string
        // drawn in a panel's bar, and the view below carries its own heading —
        // so the window said its name twice, one line above the other.
        title = ""
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isFloatingPanel = true
        // Above the shot overlay it is read from, which sits at screen-saver
        // level; anything lower and the window would open behind the very
        // picture it is describing.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 320)
        contentView = content
        center()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// ⌘C, ⌘A and friends, dispatched by hand.
    ///
    /// These are ordinarily key equivalents of the Edit menu, and an
    /// `.accessory` app has no menu bar to carry them — so selecting the
    /// recognised text and pressing ⌘C did nothing at all, and the only way
    /// out was the button. Same fix as `NotchPanel` makes for its text fields,
    /// and for the same reason: caught in `sendEvent`, because
    /// `performKeyEquivalent` is only ever called for `NSApplication`'s key
    /// window and an inactive app considers itself to have none.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let action = editingAction(for: event),
           let responder = firstResponder, responder.tryToPerform(action, with: self) {
            return
        }
        super.sendEvent(event)
    }

    private func editingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return nil }
        switch event.keyCode {
        case 0: return #selector(NSText.selectAll(_:))   // A
        case 8: return #selector(NSText.copy(_:))        // C
        default: return nil
        }
    }

    /// Grows when a translation appears and shrinks when it goes.
    ///
    /// Sized to what is in it: plain recognition is one block of text and a
    /// tall window would be mostly empty, while a translation doubles what
    /// there is to read and a short window would make both halves into
    /// letterboxes. Anchored at the top edge, so the window opens downwards
    /// rather than jumping under the pointer.
    func setTranslationVisible(_ visible: Bool) {
        let height: CGFloat = visible ? 600 : 380
        guard abs(frame.height - height) > 1 else { return }
        var target = frame
        target.origin.y -= height - frame.height
        target.size.height = height
        // Keep it on the screen it is on: growing downwards off the bottom is
        // how the buttons end up under the Dock.
        if let visibleFrame = screen?.visibleFrame, target.minY < visibleFrame.minY {
            target.origin.y = visibleFrame.minY
        }
        setFrame(target, display: true, animate: true)
    }
}

/// The picture on the left, what it says on the right.
struct ShotTextReader: View {
    @ObservedObject var translator: Translator
    @ObservedObject var settings: Settings
    let image: CGImage
    var onCopy: (String) -> Void
    /// Raised when the window has to change height for what is now in it.
    var onTranslationVisible: (Bool) -> Void

    @State private var text = ""
    @State private var isReading = true
    @State private var showsTranslation = false
    @State private var configuration: TranslationSession.Configuration?
    @State private var copied: String?

    private var preview: NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    var body: some View {
        HStack(spacing: 0) {
            picture
            Divider()
            reading
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: settings.ocrLanguage) { await read() }
        .translationTask(configuration) { session in
            await translator.run(session)
        }
    }

    /// What was read, kept in sight while the reading is checked. Half the work
    /// with OCR is comparing the two, and a window that shows only the answer
    /// makes that a memory test.
    private var picture: some View {
        Image(nsImage: preview)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .frame(width: 250)
            .background(Color.black.opacity(0.22))
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            source
            if showsTranslation { translation }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(localized("Recognised Text"), systemImage: "text.viewfinder")
                .font(.system(size: 13, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 8)
            // The language belongs here rather than on the shot's own toolbar,
            // where it used to be: it is a property of the reading, it is
            // adjusted while looking at what the reading got wrong, and moving
            // it here means changing it simply re-reads the picture that is
            // already on screen.
            Picker("", selection: $settings.ocrLanguage) {
                Text(localized("Automatic")).tag("")
                Divider()
                ForEach(TextRecognizer.supported, id: \.self) { code in
                    Text(TextRecognizer.name(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
            .help(localized("Language of the text to recognise"))
        }
    }

    @ViewBuilder
    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isReading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized("Reading…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                .background(panelBackground)
            } else {
                textBlock(text.isEmpty ? localized("No text found here.") : text, dimmed: text.isEmpty)
            }

            // No Close button: the window already has a red dot in its corner
            // and answers Esc, and a third way out was taking the space the
            // two actions that matter should have. Copy sits where the eye
            // lands first, Translate where the button used to be.
            HStack(spacing: 8) {
                Button {
                    copy(text)
                } label: {
                    Label(
                        copied == text ? localized("Copied") : localized("Copy"),
                        systemImage: copied == text ? "checkmark" : "doc.on.doc"
                    )
                }
                .disabled(text.isEmpty || isReading)

                Spacer()

                if !showsTranslation {
                    Button {
                        translate()
                    } label: {
                        Label(localized("Translate"), systemImage: "translate")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty || isReading)
                }
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var translation: some View {
        let route = Translator.route(for: text)
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "\(Translator.name(route.source)) → \(Translator.name(route.target))",
                systemImage: "arrow.right"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

            if let failure = translator.failure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if translator.needsDownload {
                        Button(localized("Open Language Settings")) {
                            Translator.openLanguageSettings()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(panelBackground)
            } else if translator.output.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized("Translating…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
                .background(panelBackground)
            } else {
                textBlock(translator.output, dimmed: false)
                HStack(spacing: 8) {
                    Button {
                        copy(translator.output)
                    } label: {
                        Label(
                            copied == translator.output ? localized("Copied") : localized("Copy Translation"),
                            systemImage: copied == translator.output ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.22))
    }

    private func textBlock(_ string: String, dimmed: Bool) -> some View {
        ScrollView(showsIndicators: true) {
            Text(string)
                .font(.system(size: 13))
                .foregroundStyle(dimmed ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 120, maxHeight: 190)
        .background(panelBackground)
    }

    // MARK: - Work

    /// Re-run whenever the language changes, on the picture the window was
    /// opened with — no second trip to the screen, which has moved on anyway.
    private func read() async {
        isReading = true
        setTranslation(false)
        translator.clear()
        let languages = settings.ocrLanguage.isEmpty ? [] : [settings.ocrLanguage]
        let result = await TextRecognizer.recognize(image, languages: languages)
        text = result
        isReading = false
    }

    private func copy(_ string: String) {
        guard !string.isEmpty else { return }
        onCopy(string)
        copied = string
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copied == string { copied = nil }
        }
    }

    private func translate() {
        setTranslation(true)
        translator.input = text
        let route = translator.route
        configuration = TranslationSession.Configuration(source: route.source, target: route.target)
    }

    private func setTranslation(_ visible: Bool) {
        guard showsTranslation != visible else { return }
        showsTranslation = visible
        onTranslationVisible(visible)
    }
}
