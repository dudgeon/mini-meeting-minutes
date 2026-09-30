@preconcurrency import AVFoundation
import Testing

@testable import MinutesCore

/// Streaming conversion must produce the same samples as converting everything at once;
/// the pipeline feeds small, reused buffers.
@Suite struct ResamplerTests {
    static func signal(rate: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { index in
            let t = Double(index) / rate
            return Float(0.4 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 1_234 * t * (1 + t)))
        }
    }

    /// Reference: one AVAudioConverter call over the whole signal.
    static func oneShot(_ samples: [Float], rate: Double, quality: AVAudioQuality = .high) -> [Float] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = AVAudioFrameCount(samples.count)
        input.floatChannelData![0].update(from: samples, count: samples.count)
        let converter = AVAudioConverter(from: format, to: Resampler.outputFormat)!
        converter.sampleRateConverterQuality = quality.rawValue
        let output = AVAudioPCMBuffer(
            pcmFormat: Resampler.outputFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        let feeder = OneShotInput(input)
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            let buffer = feeder.next(status)
            if buffer == nil { status.pointee = .endOfStream }
            return buffer
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func maxDifference(_ a: [Float], _ b: [Float], skip: Int = 64) -> Float {
        let count = min(a.count, b.count)
        guard count > 2 * skip else { return .infinity }
        return (skip..<(count - skip)).map { abs(a[$0] - b[$0]) }.max() ?? 0
    }

    @Test(arguments: [48_000.0, 44_100.0, 16_000.0])
    func fileResamplerStreamsExactly(rate: Double) throws {
        let samples = Self.signal(rate: rate, seconds: 2)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let resampler = try Resampler(inputFormat: format)
        // One buffer, refilled for every block.
        let block = 512
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
        var output: [Float] = []
        var position = 0
        while position < samples.count {
            let count = min(block, samples.count - position)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 {
                buffer.floatChannelData![channel].update(from: Array(samples[position..<(position + count)]), count: count)
            }
            output += try resampler.convert(buffer)
            position += count
        }
        let reference = rate == 16_000 ? samples : Self.oneShot(samples, rate: rate)
        #expect(abs(output.count - reference.count) < 64)
        #expect(Self.maxDifference(output, reference) < 1e-3)
    }

    @Test(arguments: [48_000.0, 44_100.0])
    func captureResamplerStreamsExactly(rate: Double) throws {
        let samples = Self.signal(rate: rate, seconds: 2)
        let resampler = try #require(TimestampedResampler(inputRate: rate, outputRate: 16_000))
        var output: [Float] = []
        var hostTime = HostTime.now()
        for start in stride(from: 0, to: samples.count, by: 512) {
            let block = Array(samples[start..<min(start + 512, samples.count)])
            block.withUnsafeBufferPointer { pointer in
                resampler.process(pointer, hostTime: hostTime) { chunk, _ in output += chunk }
            }
            hostTime += HostTime.ticks(Double(block.count) / rate)
        }
        let reference = Self.oneShot(samples, rate: rate, quality: .max)
        #expect(abs(output.count - reference.count) < 64)
        #expect(Self.maxDifference(output, reference) < 1e-3)
    }
}
