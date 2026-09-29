@preconcurrency import AVFoundation

/// Mono Float32 -> mono Float32 sample-rate conversion that stamps each emitted chunk with the
/// host time of its first sample.
///
/// Timing model: AVAudioConverter's default prime method (`.normal`) is zero-latency, i.e. output
/// frame k corresponds to input frame k * inRate / outRate (AVAudioConverter.h). Every input buffer
/// is recorded as an anchor (input frame index -> host time), so each output timestamp is derived
/// from the *nearest preceding hardware timestamp*, not from a running sample count. That keeps
/// stamps locked to the host clock even though the device clock drifts by tens of ppm.
/// A host-time jump larger than `gapTolerance` (IO restart, dropped cycles, quiesced tap) starts a
/// new segment: the converter is reset and the gap stays visible in the timestamps.
///
/// Not thread-safe: confine to one serial queue. Allocates, so never call it on the IO thread.
final class TimestampedResampler {
    let inputRate: Double
    let outputRate: Double
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var outputBuffer: AVAudioPCMBuffer
    private let gapTolerance: Double
    private var anchors: [(frame: Double, hostTime: UInt64)] = []
    private var segmentInputFrames: Double = 0
    private var segmentOutputFrames: Double = 0
    private var nextExpectedHostTime: UInt64?

    init?(inputRate: Double, outputRate: Double, initialCapacity: Int = 4096, gapTolerance: Double = 0.020) {
        guard inputRate > 0, outputRate > 0,
              let inFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                               frameCapacity: Self.outputCapacity(initialCapacity, inputRate, outputRate))
        else { return nil }
        if inputRate == outputRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            // Mono in, mono out: no channel mapping involved (AVAudioConverter's implicit downmix is
            // unreliable for non-stereo layouts, see MicrophoneCapture's channel policy).
            self.converter = converter
        }
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.inputFormat = inFormat
        self.outputFormat = outFormat
        self.outputBuffer = outBuffer
        self.gapTolerance = gapTolerance
    }

    private static func outputCapacity(_ inputFrames: Int, _ inRate: Double, _ outRate: Double) -> AVAudioFrameCount {
        AVAudioFrameCount((Double(inputFrames) * outRate / inRate).rounded(.up)) + 64
    }

    /// Discards converter state and timing anchors (next buffer starts a new segment).
    func startNewSegment() {
        converter?.reset()
        anchors.removeAll(keepingCapacity: true)
        segmentInputFrames = 0
        segmentOutputFrames = 0
        nextExpectedHostTime = nil
    }

    /// `hostTime` is the host time of `samples[0]`; pass 0 if unknown.
    func process(_ samples: UnsafeBufferPointer<Float>, hostTime rawHostTime: UInt64,
                 emit: (_ samples: [Float], _ hostTime: UInt64) -> Void) {
        let count = samples.count
        guard count > 0, let base = samples.baseAddress else { return }
        var hostTime = rawHostTime
        if hostTime == 0 { hostTime = nextExpectedHostTime ?? HostTime.now() }
        if let expected = nextExpectedHostTime, abs(HostTime.seconds(from: expected, to: hostTime)) > gapTolerance {
            startNewSegment()
        }
        anchors.append((segmentInputFrames, hostTime))
        segmentInputFrames += Double(count)
        nextExpectedHostTime = hostTime &+ HostTime.ticks(Double(count) / inputRate)

        guard let converter else {
            emit(Array(samples), hostTime)
            segmentOutputFrames += Double(count)
            anchors.removeAll(keepingCapacity: true)
            return
        }

        // A fresh input buffer every call: AVAudioConverter can keep reading the buffer it was
        // given after `convert` returns, so refilling a shared one corrupts the audio.
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else {
            return
        }
        input.frameLength = AVAudioFrameCount(count)
        input.floatChannelData![0].update(from: base, count: count)
        let needed = Self.outputCapacity(count, inputRate, outputRate)
        if outputBuffer.frameCapacity < needed {
            guard let bigger = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: needed) else { return }
            outputBuffer = bigger
        }

        let feeder = OneShotInput(input)
        while true {
            outputBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
                feeder.next(inputStatus)
            }
            let produced = Int(outputBuffer.frameLength)
            if produced > 0 {
                let stamp = hostTimeForOutputFrame(segmentOutputFrames)
                emit(Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: produced)), stamp)
                segmentOutputFrames += Double(produced)
            }
            // `.haveData` with a full buffer means more output is pending; anything else means the
            // converter consumed the input and is holding only its look-ahead frames.
            if status != .haveData || produced < Int(outputBuffer.frameCapacity) { break }
        }
    }

    private func hostTimeForOutputFrame(_ outputFrame: Double) -> UInt64 {
        let inputPosition = outputFrame * inputRate / outputRate
        while anchors.count > 1, anchors[1].frame <= inputPosition { anchors.removeFirst() }
        guard let anchor = anchors.first else { return nextExpectedHostTime ?? HostTime.now() }
        return anchor.hostTime &+ HostTime.ticks((inputPosition - anchor.frame) / inputRate)
    }
}

/// Feeds one buffer to AVAudioConverter, then reports `.noDataNow` so the converter keeps its
/// filter state for the next call. A class because the input block is `@Sendable` and cannot
/// capture a mutable local (same pattern as pasrom/meeting-transcriber `FeedOnce`).
final class OneShotInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if consumed {
            status.pointee = .noDataNow
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
