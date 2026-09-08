import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var privacyItem: NSMenuItem?
    private var privacyAllItem: NSMenuItem?
    private var privacySectionItems: [PrivacyMode.Section: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Системную плашку мы могли остановить сигналом — отпускаем обратно,
        // иначе у пользователя останется макбук без индикатора громкости.
        SystemHUD.restore()
        controller?.teardown()
    }

    /// Reopen is the one gesture left once the icon is hidden: launching
    /// Cyclop.app again from Finder or Spotlight while it is already running.
    /// `LSUIElement` gives it no Dock icon and no window to raise, but this
    /// delegate method still fires — it is how the icon comes back (#5).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        return true
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "eye.fill",
            accessibilityDescription: "Cyclop"
        )
        item.button?.image?.isTemplate = true
        // Lets the icon be ⌘-dragged off the bar, the way any status item can
        // be; `autosaveName` is what makes AppKit remember that across
        // relaunches on its own, the same mechanism the explicit switch in
        // Settings uses through `AppDelegate.isMenuBarIconVisible` below (#5).
        item.behavior = .removalAllowed
        item.autosaveName = "CyclopMenuBarIcon"

        let menu = NSMenu()
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

        // Sits next to the panel switch rather than in the Settings tab: it
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

    /// Everything shown is re-read when the menu opens, not kept fresh in
    /// between: a menu nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        refreshPrivacyItems()
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
}

extension AppDelegate {
    /// Whether the status item shows at all. Reachable from the Settings tab
    /// (#5) the same way `NotchGeometry.showsOnAllDisplays` reaches its own
    /// piece of state — through the one `AppDelegate` the app has, rather than
    /// threading a reference through the view hierarchy for a single switch.
    ///
    /// Nothing to migrate to `config.json` (#67): AppKit already persists this
    /// through `autosaveName`, which is also what a ⌘-drag off the bar updates
    /// — the two paths to the same off state agree because they are the same
    /// state.
    @MainActor
    static var isMenuBarIconVisible: Bool {
        get { (NSApp.delegate as? AppDelegate)?.statusItem?.isVisible ?? true }
        set { (NSApp.delegate as? AppDelegate)?.statusItem?.isVisible = newValue }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

