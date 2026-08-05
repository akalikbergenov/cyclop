import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var clearVaultItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
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

        let login = NSMenuItem(
            title: localized("Launch at Login"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(featuresItem())
        menu.addItem(paneSpeedItem())

        let saveShots = NSMenuItem(
            title: localized("Save Clipboard Screenshots"),
            action: #selector(toggleSaveClipboardImages),
            keyEquivalent: ""
        )
        saveShots.target = self
        saveShots.state = NotchViewModel.saveClipboardImagesEnabled ? .on : .off
        menu.addItem(saveShots)

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

    // MARK: - Features

    private func featuresItem() -> NSMenuItem {
        let item = NSMenuItem(title: localized("Show in Panel"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let enabled = NotchViewModel.Tab.enabled
        for tab in NotchViewModel.Tab.leftRail + NotchViewModel.Tab.rightRail {
            let entry = NSMenuItem(title: tab.title, action: #selector(toggleFeature(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = tab.rawValue
            entry.state = enabled.contains(tab) ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let tab = NotchViewModel.Tab(rawValue: raw) else { return }
        var enabled = NotchViewModel.Tab.enabled
        if enabled.contains(tab) {
            // The panel always needs one way in — the last tab standing
            // cannot be switched off.
            guard enabled.count > 1 else { return }
            enabled.remove(tab)
        } else {
            enabled.insert(tab)
        }
        NotchViewModel.Tab.enabled = enabled
        sender.state = enabled.contains(tab) ? .on : .off
    }

    // MARK: - Pane switch speed

    private func paneSpeedItem() -> NSMenuItem {
        let item = NSMenuItem(title: localized("Switch Smoothness"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for speed in Theme.PaneSpeed.allCases {
            let entry = NSMenuItem(
                title: speed.title,
                action: #selector(selectPaneSpeed(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.tag = speed.rawValue
            entry.state = Theme.paneSpeed == speed ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectPaneSpeed(_ sender: NSMenuItem) {
        guard let speed = Theme.PaneSpeed(rawValue: sender.tag) else { return }
        Theme.paneSpeed = speed
        for entry in sender.menu?.items ?? [] {
            entry.state = entry.tag == sender.tag ? .on : .off
        }
    }

    /// The size is measured when the menu opens, not kept fresh in between: a
    /// folder nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        guard let clearVaultItem else { return }
        let usage = ScreenshotVault.usage()
        if usage.files == 0 {
            clearVaultItem.title = localized("Clear Screenshots Folder")
            clearVaultItem.isEnabled = false
        } else {
            let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
            clearVaultItem.title = localized("Clear Screenshots Folder (%@)", size)
            clearVaultItem.isEnabled = true
        }
    }

    @objc private func clearScreenshots() {
        ScreenshotVault.clear()
        // The cards pointing into that folder just went to the Trash with it.
        controller?.reloadShelf()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleSaveClipboardImages(_ sender: NSMenuItem) {
        UserDefaults.standard.set(
            !NotchViewModel.saveClipboardImagesEnabled,
            forKey: NotchViewModel.saveClipboardImagesKey
        )
        sender.state = NotchViewModel.saveClipboardImagesEnabled ? .on : .off
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

