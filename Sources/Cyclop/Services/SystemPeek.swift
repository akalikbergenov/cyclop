import AppKit
import CoreAudio
import Combine
import IOKit.ps

/// Короткое объявление в свёрнутой чёлке.
///
/// Не вкладка и не панель: строчка, которая приезжает сама, живёт пару секунд
/// и уезжает. Клика не ждёт и кликов не берёт — панель в этот момент остаётся
/// прозрачной для указателя, иначе объявление о смене трека перехватывало бы
/// нажатие на пункт меню-бара рядом.
struct PeekEvent: Equatable {
    var symbol: String
    var title: String
    /// Правая половина строки: имя исполнителя, проценты заряда.
    var detail: String?
    /// Полоса под строкой, 0…1. Есть у громкости и заряда, нет у трека.
    var progress: Double?
    /// Чтобы одинаковые события подряд считались разными и таймер перезапускался.
    var stamp = Date()

    static func == (lhs: PeekEvent, rhs: PeekEvent) -> Bool {
        lhs.symbol == rhs.symbol && lhs.title == rhs.title
            && lhs.detail == rhs.detail && lhs.progress == rhs.progress
            && lhs.stamp == rhs.stamp
    }
}

/// Питание: воткнули или вынули шнур.
///
/// `IOPSNotificationCreateRunLoopSource` будит нас на любое изменение источника
/// питания, разрешений не спрашивает и не опрашивает ничего по таймеру.
@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var isCharging = false
    @Published private(set) var percent: Int = 0

    /// Зовётся, когда шнур воткнули или вынули — но не когда просто изменился
    /// процент: объявлять каждый процент значит объявлять непрерывно.
    var onPlugChange: ((Bool, Int) -> Void)?

    private var source: CFRunLoopSource?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        read(announce: false)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.read(announce: true) }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        source = nil
        started = false
    }

    private func read(announce: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for item in list {
            guard let source = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            let capacity = source[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = source[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = source[kIOPSPowerSourceStateKey] as? String
            let plugged = state == kIOPSACPowerValue

            let newPercent = max > 0 ? Int((Double(capacity) / Double(max) * 100).rounded()) : 0
            let changed = plugged != isCharging
            isCharging = plugged
            percent = newPercent
            if announce, changed { onPlugChange?(plugged, newPercent) }
            return
        }
    }
}

/// Громкость устройства вывода.
///
/// Слушатель свойства, а не опрос: CoreAudio сам зовёт нас, когда громкость
/// поменялась — хоть с клавиатуры, хоть из другого приложения.
@MainActor
final class VolumeMonitor: ObservableObject {
    @Published private(set) var level: Double = 0
    @Published private(set) var muted = false

    var onChange: ((Double, Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?
    private var started = false

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard !started else { return }
        device = Self.defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        started = true
        read(announce: false)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.read(announce: true) }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(device, &Self.volumeAddress, nil, block)
        AudioObjectAddPropertyListenerBlock(device, &Self.muteAddress, nil, block)
    }

    func stop() {
        if let listener, device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &Self.volumeAddress, nil, listener)
            AudioObjectRemovePropertyListenerBlock(device, &Self.muteAddress, nil, listener)
        }
        listener = nil
        device = AudioObjectID(kAudioObjectUnknown)
        started = false
    }

    private func read(announce: Bool) {
        guard device != kAudioObjectUnknown else { return }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &Self.volumeAddress, 0, nil, &size, &value) == noErr else { return }

        var muteValue = UInt32(0)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &Self.muteAddress, 0, nil, &muteSize, &muteValue) == noErr {
            muted = muteValue != 0
        }

        level = Double(value)
        if announce { onChange?(level, muted) }
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return id
    }
}

/// Системная плашка громкости и яркости.
///
/// Своей плашки у macOS не отнять: публичного способа её выключить нет, и
/// приложения, которые рисуют собственную, все до одного останавливают процесс
/// `OSDUIHelper` сигналом. Это костыль, и называть его иначе нечестно —
/// поэтому он выключен по умолчанию, останавливается только по просьбе и
/// отпускается обратно при выходе, включая аварийный.
///
/// Процесс перезапускается системой сам, когда понадобится, так что худшее,
/// что бывает при промахе, — вернувшаяся системная плашка.
@MainActor
enum SystemHUD {
    private static let identifier = "com.apple.OSDUIHelper"
    private(set) static var isSuppressed = false

    static func suppress() {
        guard !isSuppressed else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            kill(app.processIdentifier, SIGSTOP)
        }
        isSuppressed = true
    }

    static func restore() {
        guard isSuppressed else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            kill(app.processIdentifier, SIGCONT)
        }
        isSuppressed = false
    }
}
