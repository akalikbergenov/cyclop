import SwiftUI
import ServiceManagement

/// What used to live in the status bar menu, minus the two items that belong
/// there: opening the panel and hiding its contents are both things people
/// reach for in a hurry, often without wanting to open the panel at all — the
/// rest is configuration, read rarely, and reads better as a tab like any
/// other than as a menu that grows a new row per feature.
struct SettingsPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    let screenshots: ScreenshotFolderWatcher

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var menuBarIconVisible = AppDelegate.isMenuBarIconVisible
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var allDisplays = NotchGeometry.showsOnAllDisplays
    @State private var watchScreenshotFolder = false
    @State private var visualizer = AudioTap.isEnabled
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(localized("General")) {
                    toggleRow(
                        symbol: "arrow.forward.to.line",
                        title: localized("Launch at Login"),
                        isOn: launchAtLoginBinding
                    )
                    // Off means the same thing a ⌘-drag off the bar does —
                    // both go through `AppDelegate.isMenuBarIconVisible`, so
                    // whichever one somebody used, this switch shows it (#5).
                    toggleRow(
                        symbol: "eye.fill",
                        title: localized("Show Menu Bar Icon"),
                        isOn: menuBarIconVisibleBinding
                    )
                }

                // The rail is for what gets a glance between other things.
                // A tab used once a month is not banned from it, but it lives
                // there only as long as whoever never uses it can take it off —
                // and off means quiet too: its background stops with the icon.
                section(localized("Show in Panel")) {
                    ForEach(NotchViewModel.Tab.leftRail + NotchViewModel.Tab.rightRail) { tab in
                        if tab.canHide {
                            toggleRow(symbol: tab.symbol, title: tab.title, isOn: visibilityBinding(tab))
                        }
                    }
                }

                // Спектр играющего. Включение здесь, а не где-нибудь ещё,
                // потому что это единственное место, где нажатие точно
                // сделано человеком при открытой панели — а системный вопрос
                // про доступ к звуку иначе приходит без фокуса.
                section(localized("Visualizer")) {
                    toggleRow(
                        symbol: "waveform",
                        title: localized("Show Spectrum"),
                        isOn: visualizerBinding
                    )
                }

                section(localized("Displays")) {
                    toggleRow(
                        symbol: "display.2",
                        title: localized("Show on All Displays"),
                        isOn: allDisplaysBinding
                    )
                }

                section(localized("Screenshots")) {
                    toggleRow(
                        symbol: "photo.on.rectangle",
                        title: localized("Save Clipboard Screenshots"),
                        isOn: saveClipboardImagesBinding
                    )
                    toggleRow(
                        symbol: "eye",
                        title: localized("Watch Screenshots Folder"),
                        isOn: watchScreenshotFolderBinding
                    )
                    actionRow(symbol: "folder", title: localized("Show Screenshots Folder")) {
                        ScreenshotVault.reveal()
                    }
                    actionRow(
                        symbol: "trash",
                        title: clearTitle,
                        disabled: screenshotUsage.files == 0
                    ) {
                        ScreenshotVault.clear()
                        shelf.load()
                        // The files were just deleted, so the cards have to go
                        // with them. Safe to look here: the vault lives in the
                        // app's own folder, which macOS does not guard.
                        shelf.refreshFromDisk()
                        refreshUsage()
                    }
                }

                section(localized("Snippets")) {
                    actionRow(symbol: "doc.text", title: localized("Show Snippets File")) {
                        SnippetStore.reveal()
                    }
                }

                // The one door left once the menu bar icon is gone (#5): a
                // status item is not required to hide it any more, so quitting
                // must not require one either.
                section(localized("Cyclop")) {
                    actionRow(symbol: "power", title: localized("Quit Cyclop")) {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (#11 taught the same lesson for the menu
        // this replaces).
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            // Also flipped by a ⌘-drag off the bar, not only by the switch
            // below it — re-read for the same reason as the rest of this block.
            menuBarIconVisible = AppDelegate.isMenuBarIconVisible
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            allDisplays = NotchGeometry.showsOnAllDisplays
            watchScreenshotFolder = screenshots.isEnabled
            visualizer = AudioTap.isEnabled
            refreshUsage()
        }
    }

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    private var visualizerBinding: Binding<Bool> {
        Binding(
            get: { visualizer },
            set: { wants in
                visualizer = wants
                AudioTap.isEnabled = wants
                if wants {
                    // На миг становимся активным приложением: системный запрос
                    // доступа к звуку иначе приходит без фокуса и висит.
                    NSApp.activate(ignoringOtherApps: true)
                    vm.audio.start()
                } else {
                    vm.audio.stop()
                }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wants in
                do {
                    if wants {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private var menuBarIconVisibleBinding: Binding<Bool> {
        Binding(
            get: { menuBarIconVisible },
            set: { wants in
                menuBarIconVisible = wants
                AppDelegate.isMenuBarIconVisible = wants
            }
        )
    }

    private func visibilityBinding(_ tab: NotchViewModel.Tab) -> Binding<Bool> {
        Binding(
            get: { vm.isVisible(tab) },
            set: { wants in vm.setVisible(tab, wants) }
        )
    }

    private var saveClipboardImagesBinding: Binding<Bool> {
        Binding(
            get: { saveClipboardImages },
            set: { wants in
                saveClipboardImages = wants
                UserDefaults.standard.set(wants, forKey: NotchViewModel.saveClipboardImagesKey)
            }
        )
    }

    /// Turning this off folds the panel back to one screen — the notched one
    /// if this Mac has a notch, the main display otherwise. The panels are
    /// rebuilt on the spot, so the switch is its own confirmation.
    private var allDisplaysBinding: Binding<Bool> {
        Binding(
            get: { allDisplays },
            set: { wants in
                allDisplays = wants
                NotchGeometry.showsOnAllDisplays = wants
            }
        )
    }

    /// Turning off is instant. Turning on goes through the Open panel first —
    /// `requestAccess` is itself the consent, so the switch only follows what
    /// actually happened once the panel closes, not the click that opened it.
    private var watchScreenshotFolderBinding: Binding<Bool> {
        Binding(
            get: { watchScreenshotFolder },
            set: { wants in
                if wants {
                    screenshots.requestAccess { granted in watchScreenshotFolder = granted }
                } else {
                    screenshots.disable()
                    watchScreenshotFolder = false
                }
            }
        )
    }

    /// Off the main thread: walking the folder takes as long as the folder is
    /// big, and this is the thread the whole panel lives on (#11).
    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = ScreenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
            VStack(spacing: 1) {
                rows()
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
        }
    }

    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(NotchToggleStyle())
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func actionRow(
        symbol: String,
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}
