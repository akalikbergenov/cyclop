import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var picker: BufferPickerController?
    private var shot: ShotController?
    private var panelHotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var statusItem: NSStatusItem?
    private var pasteItem: NSMenuItem?
    private var bufferItem: NSMenuItem?
    private var screenshotItem: NSMenuItem?
    private var clearVaultItem: NSMenuItem?
    private var privacyItem: NSMenuItem?
    private var privacyAllItem: NSMenuItem?
    private var privacySectionItems: [PrivacyMode.Section: NSMenuItem] = [:]
    private var loginItem: NSMenuItem?
    private var saveShotsItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the panel: the panel reads the history on the way up, and the
        // store is what survives every rebuild of it.
        BufferStore.shared.start()
        controller = NotchController()
        controller?.install()
        installPicker()
        shot = ShotController()
        shot?.installHotKey()
        installStatusItem()
    }

    /// The keyboard list reads the same buffer the panel shows — there is one
    /// history, reachable two ways.
    private func installPicker() {
        let picker = BufferPickerController()
        picker.installHotKey()
        self.picker = picker

        applyPanelHotKey()
        Settings.shared.$panelHotKey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPanelHotKey() }
            }
            .store(in: &cancellables)
    }

    /// The optional shortcut that opens the panel itself. Unset by default —
    /// hovering the notch is how the panel opens, and a combination taken from
    /// every other app on the machine should be something the user asked for.
    private func applyPanelHotKey() {
        panelHotKey?.unregister()
        panelHotKey = nil
        guard let combo = Settings.shared.panelHotKey else { return }
        panelHotKey = HotKey(combo: combo) { [weak self] in
            self?.controller?.toggle()
        }
        if panelHotKey == nil {
            NSLog("Cyclop: \(combo.label) is already registered by another application")
        }
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "eye.fill",
            accessibilityDescription: "Cyclop"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        // Enabling is decided here, not guessed from the responder chain: the
        // clear item below is disabled exactly when the folder is empty.
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "Cyclop \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: localized("Open Panel"),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        // Carries its shortcut as a label as much as a binding: the picker is
        // the one feature here with no hover to discover it by, and a shortcut
        // nobody is told about is a shortcut nobody presses.
        let paste = NSMenuItem(
            title: localized("Open Buffer"),
            action: #selector(showBufferPicker),
            keyEquivalent: ""
        )
        paste.target = self
        menu.addItem(paste)
        bufferItem = paste

        // Only ever shown while the permission is missing — see `menuWillOpen`.
        // Once granted there is nothing to offer, and a settings shortcut for a
        // setting already made is one more line to read past every time.
        let grant = NSMenuItem(
            title: localized("Allow Automatic Pasting…"),
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        grant.target = self
        menu.addItem(grant)
        pasteItem = grant

        let shotItem = NSMenuItem(
            title: localized("Take Screenshot"),
            action: #selector(takeShot),
            keyEquivalent: ""
        )
        shotItem.target = self
        menu.addItem(shotItem)
        screenshotItem = shotItem

        let settingsItem = NSMenuItem(
            title: localized("Settings"),
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let login = NSMenuItem(
            title: localized("Launch at Login"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)
        loginItem = login

        // Sits next to the panel switch rather than among the folder items: it
        // changes what the panel shows, and it is the one people look for in a
        // hurry, with the camera already running.
        //
        // A submenu rather than a plain switch, because the tabs hold different
        // things and not everyone wants all of them covered. "All" comes first
        // and is what most people will ever touch; the sections below it are
        // for the case where that is too much.
        let privacy = NSMenuItem(title: localized("Hide Contents"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let all = NSMenuItem(title: localized("All"), action: #selector(togglePrivacyAll), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        privacyAllItem = all
        submenu.addItem(.separator())

        for section in PrivacyMode.Section.allCases {
            let item = NSMenuItem(
                title: section.title,
                action: #selector(togglePrivacySection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = section.rawValue
            submenu.addItem(item)
            privacySectionItems[section] = item
        }

        privacy.submenu = submenu
        menu.addItem(privacy)
        privacyItem = privacy

        let saveShots = NSMenuItem(
            title: localized("Save Clipboard Screenshots"),
            action: #selector(toggleSaveClipboardImages),
            keyEquivalent: ""
        )
        saveShots.target = self
        saveShots.state = Settings.shared.saveImages ? .on : .off
        menu.addItem(saveShots)
        saveShotsItem = saveShots

        let openFolder = NSMenuItem(
            title: localized("Show Screenshots Folder"),
            action: #selector(revealScreenshots),
            keyEquivalent: ""
        )
        openFolder.target = self
        menu.addItem(openFolder)

        // Screenshots accumulate forever by design — nothing in that folder is
        // deleted behind the user's back. This is the other half of that deal:
        // one visible, hand-operated way out, with the current size right in
        // the title so the offer names its price.
        let clearVault = NSMenuItem(
            title: localized("Clear Screenshots Folder"),
            action: #selector(clearScreenshots),
            keyEquivalent: ""
        )
        clearVault.target = self
        menu.addItem(clearVault)
        clearVaultItem = clearVault

        let openSnippets = NSMenuItem(
            title: localized("Show Snippets File"),
            action: #selector(revealSnippets),
            keyEquivalent: ""
        )
        openSnippets.target = self
        menu.addItem(openSnippets)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        controller?.toggle()
    }

    @objc private func showBufferPicker() {
        picker?.open()
    }

    @objc private func takeShot() {
        shot?.begin()
    }

    @objc private func openSettings() {
        controller?.showSettings()
    }

    @objc private func openAccessibilitySettings() {
        // Prompts first: on a Mac where the app has never asked, the system
        // dialog offers to open the same pane and adds Cyclop to the list, so
        // the user finds a row to tick rather than an empty list and a name to
        // go hunting for in Finder.
        Paster.requestTrust()
        Paster.openSettings()
    }

    /// Everything shown is re-read when the menu opens, not kept fresh in
    /// between: a menu nobody is looking at deserves no bookkeeping — and a
    /// state set once at launch quietly goes stale. Launch-at-login is the
    /// live case: System Settings can switch it off from outside, and the
    /// checkmark here used to keep claiming otherwise until relaunch (#11).
    func menuWillOpen(_ menu: NSMenu) {
        refreshPrivacyItems()
        loginItem?.state = launchAtLoginEnabled ? .on : .off
        // Re-read every time: the permission is granted outside this app, and
        // the running process only learns about it by asking again.
        pasteItem?.isHidden = Paster.isTrusted
        // The shortcut is the user's to change, so the menu asks what it is
        // rather than repeating what it used to be.
        if let combo = Settings.shared.bufferHotKey {
            bufferItem?.title = localized("Open Buffer (%@)", combo.label)
        } else {
            bufferItem?.title = localized("Open Buffer")
        }
        if let combo = Settings.shared.shotHotKey {
            screenshotItem?.title = localized("Take Screenshot (%@)", combo.label)
        } else {
            screenshotItem?.title = localized("Take Screenshot")
        }
        saveShotsItem?.state = Settings.shared.saveImages ? .on : .off

        guard let clearVaultItem else { return }
        // Off the main thread: walking the folder takes as long as the folder
        // is big, and this is the thread the whole panel lives on (#11). The
        // menu is already open when the answer lands; the title updates in
        // place.
        DispatchQueue.global(qos: .userInitiated).async { [weak clearVaultItem] in
            let usage = ScreenshotVault.usage()
            let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
            DispatchQueue.main.async {
                guard let clearVaultItem else { return }
                if usage.files == 0 {
                    clearVaultItem.title = localized("Clear Screenshots Folder")
                    clearVaultItem.isEnabled = false
                } else {
                    clearVaultItem.title = localized("Clear Screenshots Folder (%@)", size)
                    clearVaultItem.isEnabled = true
                }
            }
        }
    }

    @objc private func clearScreenshots() {
        ScreenshotVault.clear()
        // The entries pointing into that folder just went to the Trash with it.
        controller?.reloadBuffer()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func togglePrivacyAll(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy else { return }
        // Anything short of everything means "turn the rest on too"; only a
        // full house turns them all off. One press, and no state where the
        // item says All while half the sections are open.
        privacy.setCoveringAll(!privacy.coversAll)
        refreshPrivacyItems()
    }

    @objc private func togglePrivacySection(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy,
              let raw = sender.representedObject as? String,
              let section = PrivacyMode.Section(rawValue: raw) else { return }
        privacy.setCovering(section, !privacy.covers(section))
        refreshPrivacyItems()
    }

    /// The parent item carries the summary: a tick when every section is
    /// covered, a dash when some are. Without it the state is a submenu away,
    /// and this is the one switch worth reading at a glance.
    private func refreshPrivacyItems() {
        guard let privacy = controller?.privacy else { return }
        privacyItem?.state = privacy.coversAll ? .on : (privacy.coversAny ? .mixed : .off)
        privacyAllItem?.state = privacy.coversAll ? .on : .off
        for (section, item) in privacySectionItems {
            item.state = privacy.covers(section) ? .on : .off
        }
    }

    @objc private func toggleSaveClipboardImages(_ sender: NSMenuItem) {
        Settings.shared.saveImages.toggle()
        sender.state = Settings.shared.saveImages ? .on : .off
    }

    @objc private func revealScreenshots() {
        ScreenshotVault.reveal()
    }

    @objc private func revealSnippets() {
        SnippetStore.reveal()
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
        }
        sender.state = launchAtLoginEnabled ? .on : .off
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

