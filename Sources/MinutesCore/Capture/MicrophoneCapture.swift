import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Captures the default input device with AVAudioEngine's input node and delivers 16 kHz mono
/// Float32 chunks stamped with the mach host time of their first sample (`AVAudioTime.hostTime`).
///
/// Device changes: the engine follows the system default input through a private
/// `CADefaultDeviceAggregate` (measured by pasrom/meeting-transcriber), but a format change stops it
/// and posts `AVAudioEngineConfigurationChange`. Both that notification and a
/// `kAudioHardwarePropertyDefaultInputDevice` change trigger a debounced rebuild with a *fresh*
/// engine, retried with backoff while the new device reports a transient 0 Hz format.
///
/// Threading: engine lifecycle on `controlQueue`; tap blocks copy to mono on AVFoundation's tap
/// thread; conversion and all callbacks run on `processingQueue` (serial).
public final class MicrophoneCapture: @unchecked Sendable {
    public typealias SampleHandler = @Sendable (_ samples: [Float], _ hostTime: UInt64) -> Void
    public typealias EventHandler = @Sendable (_ event: Event) -> Void

    public enum Event: Sendable {
        case started(sampleRate: Double, channels: Int, device: String?)
        case restarting(reason: String)
        case restarted(sampleRate: Double, channels: Int, device: String?)
        case failed(any Error)
    }

    public struct Configuration: Sendable {
        public var outputSampleRate: Double = 16_000
        /// Requested tap block length. AVAudioNode taps support 100-400 ms (AVAudioNode.h), so this
        /// path adds >=100 ms of delivery latency; timestamps stay exact regardless.
        public var tapBufferDuration: Double = 0.1
        /// Apple voice processing (AEC against system output + noise suppression + AGC) on the input.
        public var voiceProcessing = false
        /// Pin a specific input (kAudioDevicePropertyDeviceUID), e.g. the built-in mic so AirPods
        /// used for output stay in A2DP instead of dropping to HFP. nil or absent = system default.
        public var inputDeviceUID: String?
        public var restartDelay: Double = 0.3
        public var maxRestartAttempts = 6
        public init() {}
    }

    public enum CaptureError: Error, CustomStringConvertible {
        case alreadyRunning
        case permissionDenied(AVAuthorizationStatus)
        case noInputDevice
        case invalidHardwareFormat(sampleRate: Double, channels: UInt32)

        public var description: String {
            switch self {
            case .alreadyRunning: return "microphone capture is already running"
            case .permissionDenied(let status):
                return "microphone access not granted (status \(status.rawValue)); the grant belongs to the "
                    + "responsible app (your terminal): System Settings > Privacy & Security > Microphone"
            case .noInputDevice: return "no input device"
            case .invalidHardwareFormat(let rate, let channels):
                return "input reports an invalid format (\(rate) Hz, \(channels) ch)"
            }
        }
    }

    public let configuration: Configuration
    private let onSamples: SampleHandler
    private let onEvent: EventHandler

    private let controlQueue = DispatchQueue(label: "MicrophoneCapture.control", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "MicrophoneCapture.processing", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "MicrophoneCapture.listeners")
    private let controlKey = DispatchSpecificKey<Void>()
    private let processingKey = DispatchSpecificKey<Void>()
    /// Bumped on every teardown so buffers still in flight from an old engine are ignored.
    private let generation = Atomic<Int>(0)

    // controlQueue-confined
    private var engine: AVAudioEngine?
    private var configurationObserver: (any NSObjectProtocol)?
    private var inputDeviceListener: PropertyListenerToken?
    private var isRunning = false
    private var pendingRestart: DispatchWorkItem?
    private var restartAttempt = 0

    // processingQueue-confined
    private var resampler: TimestampedResampler?
    private var resamplerGeneration = -1

    public init(configuration: Configuration = Configuration(),
                onEvent: @escaping EventHandler = { _ in },
                onSamples: @escaping SampleHandler) {
        self.configuration = configuration
        self.onEvent = onEvent
        self.onSamples = onSamples
        controlQueue.setSpecific(key: controlKey, value: ())
        processingQueue.setSpecific(key: processingKey, value: ())
    }

    deinit {
        if isRunning { stopOnControlQueue() }
    }

    // MARK: Permission (public API; the prompt names the responsible app, i.e. the terminal)

    public static var authorizationStatus: AVAuthorizationStatus { AudioPermissions.microphoneStatus }

    /// `AVCaptureDevice.requestAccess(for: .audio)` when undetermined, else the stored decision.
    public static func requestAccess() async -> Bool { await AudioPermissions.requestMicrophone() }

    // MARK: Public API

    public func start() async throws {
        // Without a grant AVAudioEngine starts fine and delivers zeros, so refuse up front.
        guard await Self.requestAccess() else { throw CaptureError.permissionDenied(Self.authorizationStatus) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controlQueue.async {
                do {
                    try self.startOnControlQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: processingKey) != nil {
            controlQueue.async { self.stopOnControlQueue() }   // called from a callback
        } else if DispatchQueue.getSpecific(key: controlKey) != nil {
            stopOnControlQueue()
        } else {
            controlQueue.sync { stopOnControlQueue() }
            processingQueue.sync {}   // no callbacks after stop() returns
        }
    }

    // MARK: Lifecycle (controlQueue)

    private func startOnControlQueue() throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }
        let (rate, channels) = try buildEngine()
        isRunning = true
        restartAttempt = 0
        inputDeviceListener = try? PropertyListenerToken(
            object: CoreAudioSupport.systemObject,
            address: CoreAudioSupport.address(kAudioHardwarePropertyDefaultInputDevice),
            queue: listenerQueue) { [weak self] in
            self?.scheduleRestart(reason: "default input device changed")
        }
        emit(.started(sampleRate: rate, channels: channels, device: currentInputName()))
    }

    private func stopOnControlQueue() {
        guard isRunning else { return }
        isRunning = false
        pendingRestart?.cancel()
        pendingRestart = nil
        inputDeviceListener?.invalidate()
        inputDeviceListener = nil
        teardownEngine()
    }

    private func buildEngine() throws -> (sampleRate: Double, channels: Int) {
        // Touching `inputNode` with no input device raises an uncatchable NSException
        // (pasrom/meeting-transcriber MicEngineSession.swift:136-141).
        guard CoreAudioSupport.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) != kAudioObjectUnknown else {
            throw CaptureError.noInputDevice
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = configuration.inputDeviceUID, let unit = input.audioUnit {
            // Must happen before the format is read / the tap installed (pasrom MicEngineSession.pin).
            var device = CoreAudioSupport.device(forUID: uid)
            if device != kAudioObjectUnknown {
                _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                         &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
        }
        if configuration.voiceProcessing {
            // Voice processing spans input and output; create both ends first or start fails with
            // -10875 (daformat/subtitles app/macos/SystemAudioTap.swift:677-701).
            _ = engine.outputNode
            _ = engine.mainMixerNode
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.invalidHardwareFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }

        let tapGeneration = generation.load(ordering: .relaxed)
        let bufferFrames = AVAudioFrameCount(max(1, format.sampleRate * configuration.tapBufferDuration))
        // format: nil = the bus's own format; a mismatching format makes this API raise an
        // NSException Swift cannot catch (pasrom issue #379). macOS 27 adds a throwing
        // `installAudioTap`, but using it would stop the app building with older SDKs.
        input.installTap(onBus: 0, bufferSize: bufferFrames, format: nil) { [weak self] buffer, when in
            let hostTime = when.isHostTimeValid ? when.hostTime : 0
            self?.handleTapBuffer(buffer.audioBufferList, frames: Int(buffer.frameLength), format: buffer.format,
                                  hostTime: hostTime, generation: tapGeneration)
        }

        // Posted on an internal queue after the engine has already stopped itself. Never tear the
        // engine down from inside the handler (AVAudioEngine.h warns it can deadlock).
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.scheduleRestart(reason: "AVAudioEngineConfigurationChange")
        }

        self.engine = engine
        do {
            engine.prepare()
            try engine.start()
        } catch {
            teardownEngine()
            throw error
        }
        return (format.sampleRate, Int(format.channelCount))
    }

    private func teardownEngine() {
        generation.wrappingAdd(1, ordering: .relaxed)
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        // AVFoundation can still have IO-unit listener blocks queued against this engine; freeing it
        // immediately crashed with EXC_BAD_ACCESS (pasrom MicEngineSession.swift:229-238).
        let retained = UncheckedSendableBox(engine)
        controlQueue.asyncAfter(deadline: .now() + 1) { _ = retained }
    }

    private func scheduleRestart(reason: String, delay: Double? = nil) {
        controlQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingRestart?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.performRestart(reason: reason) }
            self.pendingRestart = item
            self.controlQueue.asyncAfter(deadline: .now() + (delay ?? self.configuration.restartDelay), execute: item)
        }
    }

    private func performRestart(reason: String) {
        guard isRunning else { return }
        pendingRestart = nil
        emit(.restarting(reason: reason))
        teardownEngine()
        do {
            let (rate, channels) = try buildEngine()
            restartAttempt = 0
            emit(.restarted(sampleRate: rate, channels: channels, device: currentInputName()))
        } catch {
            restartAttempt += 1
            guard restartAttempt <= configuration.maxRestartAttempts else {
                emit(.failed(error))
                stopOnControlQueue()
                return
            }
            // A device that is still (dis)connecting reports 0 Hz / 0 ch for a few hundred ms.
            scheduleRestart(reason: "retry \(restartAttempt) after: \(error)",
                            delay: min(0.25 * pow(2, Double(restartAttempt)), 4))
        }
    }

    // MARK: Audio path

    /// AVFoundation tap thread (not the real-time IO thread): copy to mono and hop to the processing queue.
    private func handleTapBuffer(_ list: UnsafePointer<AudioBufferList>, frames: Int, format: AVAudioFormat,
                                 hostTime: UInt64, generation tapGeneration: Int) {
        guard frames > 0, tapGeneration == generation.load(ordering: .relaxed),
              let mono = MonoExtractor.extract(list, frames: frames, format: format) else { return }
        let sampleRate = format.sampleRate
        processingQueue.async { [weak self] in
            self?.process(mono, sampleRate: sampleRate, hostTime: hostTime, generation: tapGeneration)
        }
    }

    private func process(_ mono: [Float], sampleRate: Double, hostTime: UInt64, generation tapGeneration: Int) {
        guard tapGeneration == generation.load(ordering: .relaxed) else { return }
        if resamplerGeneration != tapGeneration || resampler?.inputRate != sampleRate {
            resampler = TimestampedResampler(inputRate: sampleRate, outputRate: configuration.outputSampleRate,
                                             initialCapacity: mono.count)
            resamplerGeneration = tapGeneration
        }
        guard let resampler else { return }
        let onSamples = self.onSamples
        mono.withUnsafeBufferPointer { samples in
            resampler.process(samples, hostTime: hostTime) { chunk, stamp in onSamples(chunk, stamp) }
        }
    }

    private func emit(_ event: Event) {
        let onEvent = self.onEvent
        processingQueue.async { onEvent(event) }
    }

    private func currentInputName() -> String? {
        if let uid = configuration.inputDeviceUID {
            let pinned = CoreAudioSupport.device(forUID: uid)
            if pinned != kAudioObjectUnknown { return CoreAudioSupport.deviceName(pinned) }
        }
        return CoreAudioSupport.deviceName(CoreAudioSupport.defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
    }
}

/// Mono extraction with an explicit channel policy instead of AVAudioConverter's implicit downmix,
/// which pasrom measured writing *silence* (no error) for every multichannel layout except plain
/// stereo; the built-in mic turns into a 3-channel discrete array when another app enables voice
/// processing (pasrom/meeting-transcriber tools/audiotap/Sources/MicChannelMap.swift).
/// Policy: 1 ch -> as is; plain stereo -> average; anything else -> channel 0 (averaging the
/// elements of a mic array comb-filters).
enum MonoExtractor {
    static func extract(_ list: UnsafePointer<AudioBufferList>, frames: Int, format: AVAudioFormat) -> [Float]? {
        guard format.commonFormat == .pcmFormatFloat32, frames > 0 else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let channels = Int(format.channelCount)

        func channel(_ index: Int) -> (base: UnsafePointer<Float>, stride: Int)? {
            let bufferIndex = format.isInterleaved ? 0 : index
            guard bufferIndex < buffers.count, let data = buffers[bufferIndex].mData else { return nil }
            let stride = format.isInterleaved ? channels : 1
            guard Int(buffers[bufferIndex].mDataByteSize) >= frames * stride * MemoryLayout<Float>.size else { return nil }
            let base = UnsafePointer(data.assumingMemoryBound(to: Float.self)) + (format.isInterleaved ? index : 0)
            return (base, stride)
        }

        var mono = [Float](repeating: 0, count: frames)
        let plainStereo = channels == 2
            && (format.channelLayout == nil || format.channelLayout?.layoutTag == kAudioChannelLayoutTag_Stereo)
        if plainStereo, let left = channel(0), let right = channel(1) {
            for frame in 0..<frames {
                mono[frame] = 0.5 * (left.base[frame * left.stride] + right.base[frame * right.stride])
            }
        } else if let first = channel(0) {
            for frame in 0..<frames { mono[frame] = first.base[frame * first.stride] }
        } else {
            return nil
        }
        return mono
    }
}

/// Moves a non-Sendable reference across a queue hop whose safety is argued at the call site.
final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
