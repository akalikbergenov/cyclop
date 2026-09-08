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
