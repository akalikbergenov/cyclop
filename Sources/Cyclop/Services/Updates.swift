import AppKit
import Sparkle

/// Self-updating through Sparkle. Once a day it fetches `appcast.xml` from the
/// latest GitHub release; a newer version is downloaded in the background,
/// checked against the EdDSA key baked into Info.plist, and put in place when
/// the app quits. This is the one request the app makes for itself rather than
/// for a tab — listed in SECURITY.md.
///
/// The switch lives in Sparkle's own user defaults, not in `config.json`:
/// Sparkle reads and writes it itself, and a second copy would only drift.
@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    /// nil when the bundle has no public key — a build made before the key
    /// existed. Sparkle refuses to start without one and says so in an alert a
    /// few seconds after launch, so without a key it is not started at all.
    private var controller: SPUStandardUpdaterController?

    /// Checking and downloading as one switch: checking without installing
    /// would only add a dialog, and that is exactly what the app does not do.
    @Published private(set) var automatic = false

    var isAvailable: Bool { controller != nil }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Called once from `applicationDidFinishLaunching`. Starting shows no
    /// UI: `SUEnableAutomaticChecks` in Info.plist answers the "check
    /// automatically?" question before Sparkle can ask it.
    func start() {
        guard controller == nil else { return }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let key, !key.isEmpty else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.controller = controller
        automatic = controller.updater.automaticallyChecksForUpdates
            && controller.updater.automaticallyDownloadsUpdates
    }

    func setAutomatic(_ on: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = on
        updater.automaticallyDownloadsUpdates = on
        automatic = on
    }

    /// The one path that does show a window: pressed by hand, so the answer
    /// — "up to date" included — is what was asked for.
    func checkNow() {
        controller?.checkForUpdates(nil)
    }
}

// `nonisolated`, not `@preconcurrency`: the protocol carries no actor, and a
// main-actor method called from elsewhere would be checked at runtime and
// trap — what took 0.8.0 down (#108). None of these touch state.
extension Updates: SPUStandardUserDriverDelegate {
    /// Without this, Sparkle logs that a background app should handle
    /// reminders gently.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Most updates never get here: they download silently and install on
    /// quit. What does — one that needs a password to replace the app, say —
    /// Sparkle would bring to the front, activating the app, if it turns up
    /// within seconds of launch. That is a dialog at launch, so it is
    /// declined: the update waits for "Check for Updates", which shows it.
    /// Later on Sparkle shows it behind other windows, and that is let be.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        !immediateFocus
    }

    /// Required once the method above can say no; nothing to add on top.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {}
}
