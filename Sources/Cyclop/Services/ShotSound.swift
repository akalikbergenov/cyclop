import AppKit

/// The shutter.
///
/// macOS's own screenshot sound, played from where the system keeps it. Using
/// the file the user already associates with taking a picture is the whole
/// point: a shutter anyone recognises says "that worked" in less time than any
/// flash of the screen, and an invented noise would just be one more app with
/// an opinion about how it should sound.
enum ShotSound {
    private static let sound: NSSound? = {
        // Where the system's own screenshot sound lives. A private folder, so
        // it is read hopefully rather than relied upon — hence the fallback.
        let system = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        if let sound = NSSound(contentsOfFile: system, byReference: true) { return sound }
        return NSSound(named: "Tink")
    }()

    @MainActor
    static func play() {
        guard Settings.shared.shotSound, let sound else { return }
        // Restarted rather than left to finish: two shots in quick succession
        // should click twice, and an `NSSound` already playing ignores `play()`.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
