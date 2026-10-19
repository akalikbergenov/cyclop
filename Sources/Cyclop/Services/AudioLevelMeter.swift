import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// What the island's equalizer stands on when it is live: the loudness of the
/// sound leaving this Mac, in a few frequency bands, smoothed the way a meter
/// is — quick to rise, slow to fall.
///
/// Read through a Core Audio process tap on the system output. That is the one
/// thing here that costs a permission: macOS asks for "System Audio Recording
/// Only" the first time the tap starts, so it is off unless switched on, and
/// runs only while the island is on screen. Nothing is kept: each buffer is
/// turned into band levels and dropped. Without the permission the tap hears
/// silence, and the island goes back to its own motion.
@MainActor
final class AudioLevelMeter: ObservableObject {
    /// Band levels 0...1, low to high, while sound has been heard; nil before.
    @Published private(set) var levels: [Float]?

    private var tap: AudioLevelTap?

    func start() {
        guard tap == nil else { return }
        let tap = AudioLevelTap()
        tap.onLevels = { [weak self] levels in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.tap != nil else { return }
                    self.levels = levels
                }
            }
        }
        guard tap.start() else {
            NSLog("Cyclop: audio tap unavailable, the island keeps its own motion")
            return
        }
        self.tap = tap
    }

    func stop() {
        tap?.stop()
        tap = nil
        levels = nil
    }
}

/// The tap itself, confined to its IO queue once started.
final class AudioLevelTap: @unchecked Sendable {
    static let bandCount = 5

    var onLevels: (@Sendable ([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.cyclop.levels", qos: .userInteractive)

    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10
    private let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    private var ring = [Float](repeating: 0, count: size)
    private var written = 0
    private var sinceAnalysis = 0
    private var sampleRate: Double = 48_000

    private var smoothed = [Float](repeating: 0, count: bandCount)
    /// Each band's level over the last second or so, in dB.
    private var average = [Float](repeating: 0, count: bandCount)
    private var heard = false
    private var lastSent: Double = 0

    func start() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else {
            return false
        }
        guard let tapUID: CFString = property(tapID, kAudioTapPropertyUID),
              let outputID: AudioObjectID = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice),
              let outputUID: CFString = property(outputID, kAudioDevicePropertyDeviceUID) else {
            stop()
            return false
        }
        if let format: AudioStreamBasicDescription = property(tapID, kAudioTapPropertyFormat) {
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                stop()
                return false
            }
            sampleRate = format.mSampleRate > 0 ? format.mSampleRate : sampleRate
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cyclop Levels",
            kAudioAggregateDeviceUIDKey: "com.cyclop.levels." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID as String,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            stop()
            return false
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        onLevels = nil
    }

    // MARK: - Analysis

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let interleaved = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * interleaved)
        guard frames > 0 else { return }
        for frame in 0..<frames {
            // Mono: the average of every channel, interleaved or not.
            var sum: Float = 0
            var channels = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buffer.mNumberChannels)
                for channel in 0..<count { sum += data[frame * count + channel] }
                channels += count
            }
            ring[written % Self.size] = channels > 0 ? sum / Float(channels) : 0
            written += 1
        }
        sinceAnalysis += frames
        // Half a window between looks: about a hundred a second at 48 kHz.
        guard sinceAnalysis >= Self.size / 2 else { return }
        sinceAnalysis = 0
        analyse()
    }

    private func analyse() {
        let n = Self.size
        let start = written % n
        var ordered = Array(ring[start...] + ring[..<start])
        vDSP.multiply(ordered, window, result: &ordered)

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                ordered.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft?.forward(input: split, output: &split)
                power.withUnsafeMutableBufferPointer { out in
                    vDSP_zvmags(&split, 1, out.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        // Bands spaced evenly on a log scale, 50 Hz to 10 kHz — how the ear
        // hears them.
        let binWidth = sampleRate / Double(n)
        var decibels = [Float](repeating: -120, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let low = 50 * pow(200, Double(band) / Double(Self.bandCount))
            let high = 50 * pow(200, Double(band + 1) / Double(Self.bandCount))
            let from = max(1, Int(low / binWidth))
            let to = min(n / 2 - 1, max(from, Int(high / binWidth)))
            var sum: Float = 0
            for bin in from...to { sum += power[bin] }
            decibels[band] = 10 * log10(sum / Float(to - from + 1) + 1e-12)
        }

        // Each band against its own recent average rather than one scale for
        // all: a mix keeps most of its energy low, and on a shared scale the
        // bass bars would sit pinned at the top while the treble never moved.
        // Against its own average every band swings around the middle — which
        // is what the bars on a phone do.
        let silent = (decibels.max() ?? -120) < -30
        for band in 0..<Self.bandCount {
            let target: Float
            if silent {
                target = 0
            } else {
                if !heard { average[band] = decibels[band] }
                average[band] += (decibels[band] - average[band]) * 0.01
                target = min(1, max(0.05, 0.3 + (decibels[band] - average[band]) / 12))
            }
            let rate: Float = target > smoothed[band] ? 0.5 : 0.12
            smoothed[band] += (target - smoothed[band]) * rate
        }
        if !silent { heard = true }

        let now = CFAbsoluteTimeGetCurrent()
        guard heard, now - lastSent >= 1.0 / 30 else { return }
        lastSent = now
        onLevels?(smoothed)
    }

    // MARK: - Properties

    private func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        if T.self == CFString.self {
            return pointer.load(as: Unmanaged<CFString>.self).takeRetainedValue() as? T
        }
        return pointer.load(as: T.self)
    }
}
