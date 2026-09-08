import Accelerate
import AVFoundation
import Combine
import CoreAudio

/// Размер окна БПФ. 1024 отсчёта на 48 кГц — это 21 мс: достаточно коротко,
/// чтобы полосы успевали за долей, и достаточно длинно, чтобы низ не размазался.
private let frameCount = 1024
private let log2n = vDSP_Length(10)

/// Держатель настройки БПФ. Отдельным объектом, потому что освобождать её
/// приходится в deinit, а deinit у изолированного класса неизолирован.
private final class FFTBox: @unchecked Sendable {
    let setup: FFTSetup

    init?() {
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetup(setup) }
}

/// Кольцо между аудиопотоком и главным актором.
///
/// Отдельный объект, а не поле класса, именно потому, что потоки разные:
/// аудиопоток реального времени не имеет права ни ждать главный актор, ни
/// что-либо выделять. Здесь он делает единственное, что ему можно, —
/// копирует отсчёты под замком.
private final class SampleRing: @unchecked Sendable {
    private var storage = [Float](repeating: 0, count: frameCount)
    private var fill = 0
    private let lock = NSLock()

    func append(_ samples: UnsafePointer<Float>, count: Int, channels: Int) {
        lock.lock()
        defer { lock.unlock() }
        // Каналы чередуются; берём первый — спектру стерео не нужно.
        let step = max(channels, 1)
        var index = 0
        while index < count {
            storage[fill] = samples[index]
            fill = (fill + 1) % frameCount
            index += step
        }
    }

    /// Копия кольца, развёрнутая от самого старого отсчёта к самому свежему.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let split = fill
        var frame = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            frame[i] = storage[(split + i) % frameCount]
        }
        return frame
    }
}

/// Спектр того, что играет — по настоящему звуку, а не по таймеру.
///
/// Читается через process tap (`AudioHardwareCreateProcessTap`, macOS 14.4+):
/// система отдаёт копию того, что уходит на устройство вывода. Замерено на
/// 0.8.0-подобной сборке: под hardened runtime, с теми же двумя правами, что
/// у Cyclop сейчас, и **без диалога разрешений** — приватный тап его не
/// поднимает. Третий ключ в entitlements не нужен, обещание «ноль разрешений»
/// остаётся в силе.
///
/// Тап живёт только пока на него смотрят. Правило проекта — не работать
/// вхолостую — здесь дороже обычного: открытый тап держит агрегатное
/// устройство и будит поток на каждый буфер.
@MainActor
final class AudioTap: ObservableObject {
    /// Полосы спектра, 0…1, слева направо от низких к высоким.
    @Published private(set) var bands: [Float] = Array(repeating: 0, count: AudioTap.bandCount)

    static let bandCount = 28

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let fft = FFTBox()
    private var running = false

    private let ring = SampleRing()
    private var timer: Timer?

    private var window = [Float](repeating: 0, count: frameCount)

    init() {
        vDSP_hann_window(&window, vDSP_Length(frameCount), Int32(vDSP_HANN_NORM))
    }

    // MARK: - Жизненный цикл

    func start() {
        guard !running else { return }
        guard let device = Self.defaultOutputUID() else { return }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Cyclop Visualizer"
        // Приватный тап виден только своему процессу — и, судя по замерам,
        // именно приватность избавляет от диалога разрешений.
        description.isPrivate = true
        description.muteBehavior = .unmuted

        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return }

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cyclop Visualizer",
            kAudioAggregateDeviceUIDKey: "com.cyclop.app.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
            return
        }

        let status = Self.makeIOProc(&procID, device: aggregate, ring: ring)
        guard status == noErr, let procID else { return stop() }

        guard AudioDeviceStart(aggregate, procID) == noErr else { return stop() }
        running = true

        // Кадры рисуются с частотой экрана, а не звука: 30 раз в секунду глазу
        // достаточно, а спектр за это время всё равно успевает смениться.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.analyse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let procID, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        procID = nil
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
        running = false
        bands = Array(repeating: 0, count: Self.bandCount)
    }


    /// Замыкание для аудиопотока создаётся здесь, а не в `start()`.
    ///
    /// `start()` изолирован главным актором, и замыкание, созданное внутри
    /// него, эту изоляцию наследует: Swift вставляет проверку очереди, а
    /// вызывается замыкание из потока CoreAudio. Проверка падает на первом же
    /// буфере — приложение умирает с SIGTRAP в `dispatch_assert_queue`.
    /// Неизолированная функция не даёт замыканию контекста, наследовать
    /// нечего, и в аудиопоток уходит то, что действительно можно там звать.
    nonisolated private static func makeIOProc(
        _ procID: inout AudioDeviceIOProcID?,
        device: AudioObjectID,
        ring: SampleRing
    ) -> OSStatus {
        AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, let raw = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let samples = raw.bindMemory(to: Float.self, capacity: count)
            ring.append(samples, count: count, channels: Int(first.mNumberChannels))
        }
    }

    // MARK: - Разбор

    private func analyse() {
        guard let fft else { return }

        var frame = ring.snapshot()
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(frameCount))

        let half = frameCount / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var complex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                frame.withUnsafeBytes { rawPtr in
                    let typed = rawPtr.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(typed.baseAddress!, 2, &complex, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fft.setup, &complex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&complex, 1, &magnitudes, 1, vDSP_Length(half))
                // Без деления на длину окна величины растут вместе с ним, и
                // любой порог в децибелах пришлось бы подбирать под размер БПФ.
                var scale = Float(1) / Float(frameCount)
                vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))
            }
        }

        bands = Self.fold(magnitudes, into: Self.bandCount, previous: bands)
    }

    /// Полосы режутся логарифмически: слух работает так же, а линейная нарезка
    /// отдала бы двадцать полос из двадцати восьми верхам, где почти пусто.
    private static func fold(_ magnitudes: [Float], into count: Int, previous: [Float]) -> [Float] {
        let usable = magnitudes.count
        var result = [Float](repeating: 0, count: count)
        for band in 0..<count {
            let lowFraction = pow(Double(band) / Double(count), 2.4)
            let highFraction = pow(Double(band + 1) / Double(count), 2.4)
            let low = max(1, Int(lowFraction * Double(usable)))
            let high = min(usable, max(low + 1, Int(highFraction * Double(usable))))
            var peak: Float = 0
            for index in low..<high where magnitudes[index] > peak { peak = magnitudes[index] }

            // Логарифм по амплитуде: без него тихое место выглядит как тишина.
            let decibels = 20 * log10(max(peak, 1e-7))
            // Пол в 60 дБ: ниже него в музыке остаётся только шум записи, а
            // выше — всё, что слышно. Полосы при этом занимают всю высоту, а
            // не жмутся к потолку, как при более широком окне.
            let normalised = Float((Double(decibels) + 60) / 60)
            let clamped = min(max(normalised, 0), 1)

            // Падение медленнее подъёма: так полоса читается как удар, а не
            // как дрожь. Ровно то, что делали аппаратные индикаторы.
            let old = band < previous.count ? previous[band] : 0
            result[band] = clamped > old ? clamped : old * 0.72 + clamped * 0.28
        }
        return result
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid as String?
    }
}
