import AppKit
import ServiceManagement
import SwiftUI

/// Settings, inside the panel.
///
/// Everything here is a row of the same shape: a name on the left, the control
/// on the right, and where a setting could surprise someone, one line saying
/// what it costs. The panel is narrow, so nothing wider than a stepper or a
/// switch is used, and the whole thing scrolls.
///
/// The panel still closes when the pointer leaves it — that is the app's one
/// rule and settings do not get an exception. Every control here is worked with
/// the pointer resting inside the panel, including the shortcut recorder, which
/// listens for keys while the pointer stays put.
struct SettingsPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var buffer: BufferStore
    @ObservedObject var privacy: PrivacyMode
    @Binding var wantsKeyboard: Bool

    /// Which recorder is armed, if any. Lives here rather than in each row so
    /// that arming one disarms the other — two rows both waiting for the next
    /// key press would both take it.
    @State private var recording: Recorder?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Re-read rather than asked once: the permission is granted outside this
    /// app, and the row has to stop nagging the moment it is.
    @State private var isTrusted = Paster.isTrusted
    /// Screen Recording, for the screenshot tool. Re-read on the way in, for
    /// the same reason as Accessibility: it is granted outside this app.
    @State private var canCapture = ScreenCapture.isPermitted

    enum Recorder: String { case buffer, panel, shot }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                section(localized("Buffer"))
                bufferRows

                section(localized("Shortcuts"))
                shortcutRows

                section(localized("Screenshots"))
                shotRows

                section(localized("Size"))
                sizeRows

                section(localized("General"))
                generalRows

                HStack {
                    Spacer()
                    Button(localized("Reset Size and Shortcuts")) {
                        settings.resetLayoutAndShortcuts()
                        recording = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
            .padding(.trailing, 4)
        }
        .padding(.top, 2)
        // The recorder needs key presses, and the panel only receives them
        // while it has asked for the keyboard.
        .onAppear {
            wantsKeyboard = true
            isTrusted = Paster.isTrusted
            canCapture = ScreenCapture.isPermitted
        }
        // macOS announces changes to the trust list. Cheaper and more accurate
        // than polling, and it is what makes the warning disappear by itself
        // the moment the box is ticked in System Settings.
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name("com.apple.accessibility.api")
            )
        ) { _ in
            isTrusted = Paster.isTrusted
            canCapture = ScreenCapture.isPermitted
        }
        .onDisappear { recording = nil }
        .background(
            KeyRecorderCatcher(isRecording: recording != nil) { event in
                capture(event)
            }
        )
    }

    // MARK: - Rows

    private var bufferRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(localized("Entries kept")) {
                HStack(spacing: 6) {
                    // The number is its own view, next to the stepper rather
                    // than inside it: a `Stepper`'s label is what
                    // `labelsHidden()` hides, so putting the value there and
                    // hiding labels leaves a pair of arrows adjusting a number
                    // nobody can see.
                    Text("\(settings.bufferLimit)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 30, alignment: .trailing)
                    Stepper(
                        "",
                        value: Binding(
                            get: { settings.bufferLimit },
                            set: { value in
                                settings.bufferLimit = value
                                // At once, not at the next copy: a number the
                                // user has just lowered has to be true of the
                                // list they are looking at.
                                buffer.applyLimit()
                            }
                        ),
                        in: Settings.bufferLimitRange,
                        step: 10
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            toggleRow(
                localized("Keep text after a restart"),
                note: localized("Copied text is written to disk. Files always are."),
                isOn: Binding(
                    get: { settings.keepTextBetweenLaunches },
                    set: { value in
                        settings.keepTextBetweenLaunches = value
                        // Turning it off takes the text off the disk now, not
                        // at the next copy.
                        buffer.rewrite()
                    }
                )
            )

            toggleRow(
                localized("Save copied images"),
                note: localized("Kept in ~/Pictures/Cyclop, otherwise they are not recorded."),
                isOn: $settings.saveImages
            )
        }
    }

    private var shortcutRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            shortcutRow(
                localized("Open the buffer"),
                recorder: .buffer,
                combo: settings.bufferHotKey
            )
            shortcutRow(
                localized("Take a screenshot"),
                recorder: .shot,
                combo: settings.shotHotKey
            )
            shortcutRow(
                localized("Open the panel"),
                recorder: .panel,
                combo: settings.panelHotKey
            )
            Text(localized("Hold modifiers and press a key. Esc cancels, ⌫ clears."))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var shotRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(localized("Recognise text in")) {
                Picker("", selection: $settings.ocrLanguage) {
                    Text(localized("Automatic")).tag("")
                    ForEach(TextRecognizer.supported, id: \.self) { code in
                        Text(TextRecognizer.name(for: code)).tag(code)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
            }

            toggleRow(localized("Shutter sound"), note: nil, isOn: $settings.shotSound)

            if !canCapture {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(localized("Screenshots need Screen Recording."))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 4)
                    Button(localized("Allow…")) {
                        ScreenCapture.requestPermission()
                        ScreenCapture.openSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private var sizeRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepperRow(
                localized("Panel width"),
                value: $settings.panelWidth,
                range: Settings.panelWidthRange,
                step: 20
            )
            stepperRow(
                localized("Panel height"),
                value: $settings.panelHeight,
                range: Settings.panelHeightRange,
                step: 8
            )
            stepperRow(
                localized("Notch width"),
                value: $settings.notchWidth,
                range: Settings.notchWidthRange,
                step: 10
            )
            Text(localized("Notch width applies to Macs without a cutout."))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var generalRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow(
                localized("Launch at Login"),
                note: nil,
                isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        setLaunchAtLogin(value)
                        // Read back rather than assumed: the registration can
                        // fail, and a switch that flips anyway is a switch that
                        // lies.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                )
            )

            toggleRow(
                localized("Open the panel on hover"),
                note: localized("Off: it opens on a click on the notch, or by its shortcut."),
                isOn: $settings.opensOnHover
            )

            toggleRow(
                localized("Hide Contents"),
                note: localized("Covers what the panel holds, for a shared screen."),
                isOn: Binding(
                    get: { privacy.coversAll },
                    set: { privacy.setCoveringAll($0) }
                )
            )

            if !isTrusted {
                accessibilityRow
            }
        }
    }

    /// Shown only while the permission is missing.
    ///
    /// Two buttons rather than one, because there are two different failures
    /// behind the same symptom. "Allow" is for the first time: nothing has been
    /// granted yet and the system dialog plus the right settings pane is all
    /// anyone needs. "Restart" is for the second, stranger one — the box is
    /// ticked and pasting is still refused, which is what happens to a build
    /// signed ad-hoc after it has been replaced by a newer one: the tick
    /// belongs to the binary that used to be there. A fresh process asks for
    /// itself, and re-ticking the box then holds.
    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(localized("Automatic pasting needs Accessibility."))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 4)
                Button(localized("Allow…")) {
                    Paster.requestTrust(force: true)
                    Paster.openSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                Button(localized("Restart")) {
                    Paster.relaunch()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
            }
            Text(localized("Already ticked? Remove Cyclop from the list, restart, and allow again."))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Building blocks

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.tertiary)
            .padding(.top, 2)
    }

    private func row<Control: View>(
        _ title: String,
        note: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                if let note {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
    }

    private func toggleRow(_ title: String, note: String?, isOn: Binding<Bool>) -> some View {
        row(title, note: note) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        row(title) {
            HStack(spacing: 6) {
                Text("\(Int(value.wrappedValue))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 30, alignment: .trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    private func shortcutRow(_ title: String, recorder: Recorder, combo: HotKeyCombo?) -> some View {
        row(title) {
            Button {
                recording = recording == recorder ? nil : recorder
                wantsKeyboard = true
            } label: {
                Text(label(for: recorder, combo: combo))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(recording == recorder ? Color.black : .white)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(recording == recorder ? Color.white : Theme.surfaceHover)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func label(for recorder: Recorder, combo: HotKeyCombo?) -> String {
        if recording == recorder { return localized("Press keys…") }
        return combo?.label ?? localized("None")
    }

    // MARK: - Recording

    private func capture(_ event: NSEvent) {
        guard let recording else { return }

        // Esc leaves the shortcut as it was; ⌫ takes it away. Neither can be
        // recorded as one: Esc is how every recorder in macOS is escaped, and
        // a shortcut that cannot be cancelled or cleared is a trap.
        if event.keyCode == 53 {
            self.recording = nil
            return
        }
        if event.keyCode == 51 {
            assign(nil, to: recording)
            self.recording = nil
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: HotKey.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        // A bare key would be taken away from the whole machine, including the
        // field the user is typing in. Ignored rather than refused with a
        // message: the recorder is still armed, and the next press with a
        // modifier held simply works.
        guard !modifiers.isEmpty else { return }

        let combo = HotKeyCombo(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers.rawValue,
            label: KeyLabel.describe(event: event, flags: flags)
        )
        assign(combo, to: recording)
        self.recording = nil
    }

    private func assign(_ combo: HotKeyCombo?, to recorder: Recorder) {
        switch recorder {
        case .buffer: settings.bufferHotKey = combo
        case .panel: settings.panelHotKey = combo
        case .shot: settings.shotHotKey = combo
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
        }
    }
}

/// How a recorded combination is written down.
enum KeyLabel {
    /// Keys that print nothing, by code. Everything else is named by what it
    /// printed when it was pressed — see `HotKeyCombo.label` for why the name
    /// is recorded rather than derived later.
    private static let named: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc", 76: "⌤",
        117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func describe(event: NSEvent, flags: NSEvent.ModifierFlags) -> String {
        var label = ""
        // The order Apple writes them in, so the row looks like every other
        // shortcut on the machine.
        if flags.contains(.control) { label += "⌃" }
        if flags.contains(.option) { label += "⌥" }
        if flags.contains(.shift) { label += "⇧" }
        if flags.contains(.command) { label += "⌘" }
        return label + key(for: event)
    }

    private static func key(for event: NSEvent) -> String {
        if let named = named[event.keyCode] { return named }
        // Ignoring modifiers, or ⌥V would be recorded as "√".
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return "#\(event.keyCode)"
        }
        return characters.uppercased()
    }
}

/// Catches key presses while a recorder is armed.
///
/// An AppKit view rather than SwiftUI's `onKeyPress`: what has to be caught is
/// a *chord*, modifiers and all, before anything else in the panel treats it as
/// a command — and the panel is inactive-but-key, which is exactly the case
/// where SwiftUI's key handling is least reliable. This sits in the responder
/// chain and takes the whole event.
private struct KeyRecorderCatcher: NSViewRepresentable {
    var isRecording: Bool
    var onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
        view.isRecording = isRecording
        // Taking first responder is what arms it; giving it back is what
        // disarms it, so nothing here eats keys once the row is closed.
        if isRecording {
            view.window?.makeFirstResponder(view)
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    final class CatcherView: NSView {
        var onKey: (NSEvent) -> Void = { _ in }
        var isRecording = false

        override var acceptsFirstResponder: Bool { isRecording }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            onKey(event)
        }

        /// Swallows ⌘-anything too. Without this, a combination with ⌘ in it
        /// is treated as a menu key equivalent and never reaches `keyDown` —
        /// so the one modifier almost every shortcut starts with would be the
        /// one that cannot be recorded.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            onKey(event)
            return true
        }
    }
}
