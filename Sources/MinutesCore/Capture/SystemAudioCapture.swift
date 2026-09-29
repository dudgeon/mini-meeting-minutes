@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Foundation

/// Captures everything the Mac plays (all processes except this one) through a Core Audio process
/// tap inside a private, tap-only aggregate device, and delivers 16 kHz mono Float32 chunks stamped
/// with the mach host time of their first sample. Nothing is written to disk.
///
/// Composition follows Chromium's `media/audio/mac/catap_audio_input_stream.mm` (tap-only private
/// aggregate, `TapAutoStart` off, drift compensation on the sub-tap, explicit nominal rate),
/// teardown order follows insidegui/AudioCap `ProcessTap.invalidate()`.
///
/// Threading:
///  - Core Audio IO thread: only `TapRingBuffer.ingest` (compiler-checked `@_noLocks`).
///  - `controlQueue` (serial): every HAL create/destroy/listener call and rebuilds.
///  - `deliveryQueue` (serial): drains the ring, resamples, calls `onSamples` / `onEvent`.
///    Hand heavy work (ASR) to another queue; the ring holds ~5-10 s before dropping.
public final class SystemAudioCapture: @unchecked Sendable {
    public typealias SampleHandler = @Sendable (_ samples: [Float], _ hostTime: UInt64) -> Void
    public typealias EventHandler = @Sendable (_ event: Event) -> Void

    public enum Event: Sendable {
        case started(deviceSampleRate: Double, channels: Int)
        case rebuilding(reason: String)
        case rebuilt(deviceSampleRate: Double, channels: Int)
        /// Re-setting the tap's own description failed after start, which Chromium treats as
        /// "no audio-capture permission" (`ProbeAudioTapPermissions`).
        case permissionProbeFailed
        /// No IO callbacks for this long although capture is running.
        case stalled(seconds: Double)
        /// This long of exact digital zeros. With a non-empty `processesOutputting`, other processes
        /// are playing, so a missing TCC grant is the likely cause: taps report success and deliver
        /// zeros without permission (daformat/subtitles PLAN.md §8b, pasrom/meeting-transcriber #524).
        case digitalSilence(seconds: Double, processesOutputting: [pid_t])
        case overflow(droppedFrames: Int)
        case failed(any Error)
    }

    public struct Configuration: Sendable {
        public var outputSampleRate: Double = 16_000
        /// Leave this process out of the global tap.
        public var excludeCurrentProcess = true
        /// Mono mixdown inside the tap. Any channel count is downmixed on the IO thread anyway.
        public var monoTap = true
        /// Nominal rate requested for the aggregate (Chromium does the same). On macOS 15+ the HAL
        /// resamples the tap if the output device runs at another rate. nil keeps the default.
        public var aggregateSampleRate: Double? = 48_000
        /// Rebuild when the default output device changes (AirPods connecting). Conservative: a
        /// global tap may survive route changes by itself (pHequals7/muesli relies on that).
        public var rebuildOnDefaultOutputChange = true
        public var settleDelay: Double = 0.5
        public var maxRebuildAttempts = 5
        public var drainInterval: DispatchTimeInterval = .milliseconds(20)
        public var stallThreshold: Double = 2
        public var silenceThreshold: Double = 5
        public init() {}
    }

    public enum CaptureError: Error, CustomStringConvertible {
        case alreadyRunning
        case permissionDenied(responsibleProcess: String?)
        case unsupportedStreamFormat(String)
        case converterUnavailable(inputRate: Double)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "capture is already running"
            case .permissionDenied(let responsible):
                return "System Audio Recording permission denied for \(responsible ?? "the responsible app"): "
                    + "System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only"
            case .unsupportedStreamFormat(let format):
                return "unsupported aggregate stream format: \(format)"
            case .converterUnavailable(let rate):
                return "cannot build a \(rate) Hz -> 16 kHz converter"
            }
        }
    }

    public let configuration: Configuration
    private let onSamples: SampleHandler
    private let onEvent: EventHandler

    private let controlQueue = DispatchQueue(label: "SystemAudioCapture.control", qos: .userInitiated)
    private let deliveryQueue = DispatchQueue(label: "SystemAudioCapture.delivery", qos: .userInitiated)
    /// Listener blocks run here and only `async` onto `controlQueue` (Chromium uses a private queue
    /// for the same reason: removing a listener can otherwise deadlock).
    private let listenerQueue = DispatchQueue(label: "SystemAudioCapture.listeners")
    private let controlKey = DispatchSpecificKey<Void>()
    private let deliveryKey = DispatchSpecificKey<Void>()

    // controlQueue-confined
    private var session: TapSession?
    private var systemListeners: [PropertyListenerToken] = []
    private var isRunning = false
    private var pendingRebuild: DispatchWorkItem?
    private var rebuildAttempt = 0

    // deliveryQueue-confined
    private var ring: TapRingBuffer?
    private var resampler: TimestampedResampler?
    private var drainTimer: (any DispatchSourceTimer)?
    private var watchdog = DeliveryWatchdog()

    public init(configuration: Configuration = Configuration(),
                onEvent: @escaping EventHandler = { _ in },
                onSamples: @escaping SampleHandler) {
        self.configuration = configuration
        self.onEvent = onEvent
        self.onSamples = onSamples
        controlQueue.setSpecific(key: controlKey, value: ())
        deliveryQueue.setSpecific(key: deliveryKey, value: ())
    }

    deinit {
        // Only reached if the owner never called stop(). Nothing else references `self` now.
        if isRunning { stopOnControlQueue() }
    }

    // MARK: Public API

    /// Creates tap + aggregate + IOProc and starts IO. The first run may show the TCC prompt and
    /// block inside Core Audio until it is answered (Chromium: "this call will time out in 60
    /// seconds"), so this suspends rather than blocking the caller's thread.
    public func start() async throws {
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

    /// Stops IO and destroys IOProc, aggregate device and tap (in that order). Idempotent.
    public func stop() {
        if DispatchQueue.getSpecific(key: deliveryKey) != nil {
            controlQueue.async { self.stopOnControlQueue() }   // called from a callback
        } else if DispatchQueue.getSpecific(key: controlKey) != nil {
            stopOnControlQueue()
        } else {
            controlQueue.sync { stopOnControlQueue() }
        }
    }

    /// Tear down and recreate the tap (e.g. after a `.stalled` event).
    public func rebuild(reason: String = "requested by client") {
        controlQueue.async { self.scheduleRebuild(reason: reason, delay: 0) }
    }

    // MARK: Lifecycle (controlQueue)

    private func startOnControlQueue() throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }
        if AudioPermissions.systemAudioStatus() == .denied {
            throw CaptureError.permissionDenied(responsibleProcess: AudioPermissions.responsibleProcess()?.path)
        }
        let session = try buildSession()
        self.session = session
        isRunning = true
        rebuildAttempt = 0
        installSystemListeners()
        startDrainTimer()
        emit(.started(deviceSampleRate: session.sampleRate, channels: session.channels))
        // Probe after AudioDeviceStart: sources disagree on whether the TCC prompt fires at
        // AudioDeviceCreateIOProcID (Chromium) or at start (Apple sample docs, dev.to "2,000 Buffers").
        if !Self.probeTapPermission(session.tapID) { emit(.permissionProbeFailed) }
    }

    private func stopOnControlQueue() {
        guard isRunning else { return }
        isRunning = false
        pendingRebuild?.cancel()
        pendingRebuild = nil
        systemListeners.forEach { $0.invalidate() }
        systemListeners.removeAll()
        if let session {
            teardown(session)
            self.session = nil
        }
        onDeliveryQueue {
            drainTimer?.cancel()
            drainTimer = nil
        }
    }

    private func buildSession() throws -> TapSession {
        let session = TapSession()
        do {
            // 1. Process tap: global mixdown of every process except ours. Never set `isExclusive`
            //    after these initializers; they already set it (exclusion list). Forcing false turns
            //    the list into "include nothing" and IO silently never runs
            //    (daformat/subtitles spike/tap/tap_probe.swift:95-100).
            var excluded: [AudioObjectID] = []
            if configuration.excludeCurrentProcess {
                let ownProcess = CoreAudioSupport.processObject(for: getpid())
                if ownProcess != kAudioObjectUnknown { excluded.append(ownProcess) }
            }
            let description = configuration.monoTap
                ? CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
                : CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            description.uuid = UUID()
            description.name = "SystemAudioCapture"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tapID = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")
            session.tapID = tapID

            // 2. Private aggregate containing only the tap. The tap list holds dictionaries with the
            //    tap UUID string, never CATapDescription objects.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SystemAudioCapture",
                kAudioAggregateDeviceUIDKey: "SystemAudioCapture-" + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")
            session.aggregateID = aggregateID

            if let rate = configuration.aggregateSampleRate {
                try? CoreAudioSupport.write(aggregateID, CoreAudioSupport.address(kAudioDevicePropertyNominalSampleRate),
                                            Float64(rate))
            }

            // 3. What the IOProc will actually receive: the aggregate's input stream virtual format
            //    (Apple's sample reads kAudioStreamPropertyVirtualFormat too). Not kAudioTapPropertyFormat,
            //    which pasrom measured as a fixed 48 kHz regardless of the delivered rate (#683).
            let format = try Self.waitForInputStreamFormat(aggregateID)
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw CaptureError.unsupportedStreamFormat(
                    "id \(CoreAudioSupport.fourCC(format.mFormatID)) flags \(format.mFormatFlags) bits \(format.mBitsPerChannel)")
            }
            session.sampleRate = format.mSampleRate
            session.channels = Int(format.mChannelsPerFrame)

            // 4. Ring + converter, attached to the delivery side before IO can produce anything.
            let ring = TapRingBuffer(sampleRate: format.mSampleRate)
            guard let resampler = TimestampedResampler(inputRate: format.mSampleRate,
                                                       outputRate: configuration.outputSampleRate,
                                                       initialCapacity: ring.slotFrames) else {
                throw CaptureError.converterUnavailable(inputRate: format.mSampleRate)
            }
            session.ring = ring
            onDeliveryQueue {
                self.ring = ring
                self.resampler = resampler
                self.watchdog = DeliveryWatchdog(now: HostTime.now())
            }

            // 5. IOProc on the HAL IO thread (no dispatch queue: with a queue the HAL dispatches the
            //    block *synchronously*, so the IO thread waits for that queue anyway).
            var procID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcID(aggregateID, tapIOProc, Unmanaged.passUnretained(ring).toOpaque(),
                                                &procID), "AudioDeviceCreateIOProcID")
            session.procID = procID
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")

            installDeviceListeners(session)
            return session
        } catch {
            teardown(session)
            throw error
        }
    }

    /// Stop device -> destroy IOProc -> (drain) -> destroy aggregate -> destroy tap.
    private func teardown(_ session: TapSession) {
        session.listeners.forEach { $0.invalidate() }
        session.listeners.removeAll()
        if let procID = session.procID {
            _ = AudioDeviceStop(session.aggregateID, procID)
            let destroyStatus = AudioDeviceDestroyIOProcID(session.aggregateID, procID)
            session.procID = nil
            let deviceGone = destroyStatus == kAudioHardwareBadDeviceError || destroyStatus == kAudioHardwareBadObjectError
            if destroyStatus != noErr, !deviceGone, let ring = session.ring {
                // The HAL may still call the IOProc: leak its context instead of risking a
                // use-after-free (Chromium catap_audio_input_stream.mm, "INTENTIONAL LEAK").
                _ = Unmanaged.passRetained(ring)
            }
        }
        // No producer any more: flush what it wrote, then detach the delivery side.
        onDeliveryQueue {
            drainOnDeliveryQueue()
            self.ring = nil
            self.resampler = nil
        }
        if session.aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(session.aggregateID)
            session.aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if session.tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(session.tapID)
            session.tapID = AudioObjectID(kAudioObjectUnknown)
        }
        session.ring = nil
    }

    // MARK: Change handling (controlQueue)

    private func installSystemListeners() {
        var watched = [(CoreAudioSupport.address(kAudioHardwarePropertyServiceRestarted), "coreaudiod restarted")]
        if configuration.rebuildOnDefaultOutputChange {
            watched.append((CoreAudioSupport.address(kAudioHardwarePropertyDefaultOutputDevice), "default output device changed"))
        }
        for (address, reason) in watched {
            let token = try? PropertyListenerToken(object: CoreAudioSupport.systemObject, address: address,
                                                   queue: listenerQueue) { [weak self] in
                guard let self else { return }
                self.controlQueue.async { self.scheduleRebuild(reason: reason, delay: self.configuration.settleDelay) }
            }
            if let token { systemListeners.append(token) }
        }
    }

    private func installDeviceListeners(_ session: TapSession) {
        let watched = [
            (CoreAudioSupport.address(kAudioDevicePropertyDeviceIsAlive), "aggregate device died"),
            (CoreAudioSupport.address(kAudioDevicePropertyNominalSampleRate), "aggregate sample rate changed"),
            (CoreAudioSupport.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
             "aggregate input streams changed"),
        ]
        for (address, reason) in watched {
            let token = try? PropertyListenerToken(object: session.aggregateID, address: address,
                                                   queue: listenerQueue) { [weak self] in
                guard let self else { return }
                self.controlQueue.async { self.verifySession(reason: reason) }
            }
            if let token { session.listeners.append(token) }
        }
    }

    /// Rebuild only if the aggregate really changed: our own nominal-rate write can echo back as a
    /// notification (Chromium compares against its configured rate for the same reason).
    private func verifySession(reason: String) {
        guard isRunning, let session else { return }
        let alive = (try? CoreAudioSupport.read(session.aggregateID,
                                                CoreAudioSupport.address(kAudioDevicePropertyDeviceIsAlive),
                                                initial: UInt32(0))) ?? 0
        let format = try? Self.readInputStreamFormat(session.aggregateID)
        if alive == 0 || format == nil || format!.mSampleRate != session.sampleRate
            || Int(format!.mChannelsPerFrame) != session.channels {
            scheduleRebuild(reason: reason, delay: configuration.settleDelay)
        }
    }

    /// Debounced: bursts of notifications during a route change collapse into one rebuild.
    private func scheduleRebuild(reason: String, delay: Double) {
        guard isRunning else { return }
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.performRebuild(reason: reason) }
        pendingRebuild = item
        controlQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func performRebuild(reason: String) {
        guard isRunning else { return }
        pendingRebuild = nil
        emit(.rebuilding(reason: reason))
        if let session {
            teardown(session)
            self.session = nil
        }
        do {
            let session = try buildSession()
            self.session = session
            rebuildAttempt = 0
            emit(.rebuilt(deviceSampleRate: session.sampleRate, channels: session.channels))
        } catch {
            rebuildAttempt += 1
            guard rebuildAttempt <= configuration.maxRebuildAttempts else {
                emit(.failed(error))
                stopOnControlQueue()
                return
            }
            // Devices report transient formats while Bluetooth profiles switch; back off.
            scheduleRebuild(reason: "retry \(rebuildAttempt) after: \(error)",
                            delay: min(configuration.settleDelay * pow(2, Double(rebuildAttempt)), 8))
        }
    }

    // MARK: Delivery (deliveryQueue)

    private func startDrainTimer() {
        onDeliveryQueue {
            guard drainTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
            timer.schedule(deadline: .now() + configuration.drainInterval, repeating: configuration.drainInterval,
                           leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.drainOnDeliveryQueue() }
            timer.resume()
            drainTimer = timer
        }
    }

    private func drainOnDeliveryQueue() {
        guard let ring, let resampler else { return }
        let onSamples = self.onSamples
        while ring.consumeNext({ samples, hostTime in
            watchdog.observe(samples, hostTime: hostTime)
            resampler.process(samples, hostTime: hostTime) { chunk, stamp in onSamples(chunk, stamp) }
        }) {}
        let dropped = ring.droppedFrames.exchange(0, ordering: .relaxed)
        if dropped > 0 { onEvent(.overflow(droppedFrames: dropped)) }

        let now = HostTime.now()
        if let stalled = watchdog.checkStall(callbacks: ring.callbacks.load(ordering: .relaxed), now: now,
                                             threshold: configuration.stallThreshold) {
            onEvent(.stalled(seconds: stalled))
        }
        if let silent = watchdog.checkSilence(now: now, threshold: configuration.silenceThreshold) {
            // Enumerating HAL processes is a HAL call: keep it off the delivery queue.
            controlQueue.async { [weak self] in
                let playing = CoreAudioSupport.processesOutputtingAudio(excluding: getpid())
                self?.emit(.digitalSilence(seconds: silent, processesOutputting: playing))
            }
        }
    }

    private func emit(_ event: Event) {
        let onEvent = self.onEvent
        deliveryQueue.async { onEvent(event) }
    }

    private func onDeliveryQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: deliveryKey) != nil { work() } else { deliveryQueue.sync(execute: work) }
    }

    // MARK: Helpers

    private static func readInputStreamFormat(_ device: AudioObjectID) throws -> AudioStreamBasicDescription {
        let streams = try CoreAudioSupport.readArray(
            device, CoreAudioSupport.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
            zero: AudioStreamID(0))
        guard let first = streams.first else {
            throw CoreAudioError("aggregate has no input stream", kAudioHardwareUnspecifiedError)
        }
        return try CoreAudioSupport.read(first, CoreAudioSupport.address(kAudioStreamPropertyVirtualFormat),
                                         initial: AudioStreamBasicDescription())
    }

    /// The tap can surface on the aggregate asynchronously (euf/audioteemic polls ~1 s for it).
    private static func waitForInputStreamFormat(_ device: AudioObjectID) throws -> AudioStreamBasicDescription {
        var lastError: any Error = CoreAudioError("aggregate input stream never appeared", kAudioHardwareUnspecifiedError)
        for _ in 0..<20 {
            do {
                let format = try readInputStreamFormat(device)
                if format.mSampleRate > 0, format.mChannelsPerFrame > 0 { return format }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw lastError
    }

    /// Chromium's `ProbeAudioTapPermissions`: read the tap description (+1 object) and set it back;
    /// failure signals a missing audio-capture grant.
    static func probeTapPermission(_ tapID: AudioObjectID) -> Bool {
        var address = CoreAudioSupport.address(kAudioTapPropertyDescription)
        var reference: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &reference) == noErr,
              let description = reference?.takeRetainedValue() else { return false }
        return withExtendedLifetime(description) {
            var pointer = Unmanaged.passUnretained(description).toOpaque()
            return AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                              UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &pointer) == noErr
        }
    }
}

/// HAL objects of one capture attempt (controlQueue-confined).
private final class TapSession {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var ring: TapRingBuffer?
    var sampleRate: Double = 0
    var channels = 0
    var listeners: [PropertyListenerToken] = []
}

/// Stall and digital-silence detection on the delivery side (daformat/subtitles PLAN.md §8b
/// recommends exactly this all-zero watchdog because a missing grant is otherwise invisible).
private struct DeliveryWatchdog {
    private var lastCallbacks = -1
    private var lastCallbackChange: UInt64 = 0
    private var stallReported = false
    private var silentSince: UInt64?
    private var silenceReported = false

    init(now: UInt64 = 0) { lastCallbackChange = now }

    mutating func observe(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        if samples.contains(where: { $0 != 0 }) {
            silentSince = nil
            silenceReported = false
        } else if silentSince == nil {
            silentSince = hostTime != 0 ? hostTime : HostTime.now()
        }
    }

    mutating func checkStall(callbacks: Int, now: UInt64, threshold: Double) -> Double? {
        if callbacks != lastCallbacks {
            lastCallbacks = callbacks
            lastCallbackChange = now
            stallReported = false
            return nil
        }
        let elapsed = HostTime.seconds(from: lastCallbackChange, to: now)
        guard !stallReported, elapsed >= threshold else { return nil }
        stallReported = true
        return elapsed
    }

    mutating func checkSilence(now: UInt64, threshold: Double) -> Double? {
        guard let since = silentSince, !silenceReported else { return nil }
        let elapsed = HostTime.seconds(from: since, to: now)
        guard elapsed >= threshold else { return nil }
        silenceReported = true
        return elapsed
    }
}
