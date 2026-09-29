@preconcurrency import AVFoundation
import Foundation

/// Converts audio of any format to 16 kHz mono Float32, keeping converter state between buffers
/// so there are no discontinuities at buffer boundaries.
public final class Resampler {
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.samplesPerSecond, channels: 1, interleaved: false)!

    public let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let mono: AVAudioFormat?

    public init(inputFormat: AVAudioFormat) throws {
        self.inputFormat = inputFormat
        // AVAudioConverter's downmix of more than two channels is unreliable, so mix to mono
        // ourselves first when needed.
        if inputFormat.channelCount > 1 {
            mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)
        } else {
            mono = nil
        }
        guard let converter = AVAudioConverter(from: mono ?? inputFormat, to: Self.outputFormat) else {
            throw ResamplerError.unsupportedFormat(inputFormat.description)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
    }

    /// Converts one buffer. Returns the samples produced so far; the converter may hold a few
    /// back until the next call.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        // Always hand the converter a buffer nobody else touches: it can keep reading a buffer
        // after `convert` returns, and callers reuse theirs.
        let input = try Self.downmix(buffer, to: mono ?? Self.monoFormat(at: buffer.format.sampleRate))
        if input.format.sampleRate == Self.outputFormat.sampleRate {
            return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
        }

        let ratio = Self.outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        let feeder = OneShotInput(input)
        var samples: [Float] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in feeder.next(inputStatus) }
            if status == .error { throw error ?? ResamplerError.unsupportedFormat(input.format.description) }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples += UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            }
            // A full buffer with `.haveData` means more output is waiting.
            if status != .haveData || output.frameLength < output.frameCapacity { break }
        }
        return samples
    }

    private static func monoFormat(at sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Averages all channels into one.
    static func downmix(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
            let destination = output.floatChannelData?[0]
        else { throw ResamplerError.unsupportedFormat(buffer.format.description) }
        output.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        if let source = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let data = source[0]
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += data[frame * channels + channel] }
                    destination[frame] = sum / Float(channels)
                }
            } else {
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += source[channel][frame] }
                    destination[frame] = sum / Float(channels)
                }
            }
        } else if let source = buffer.int16ChannelData {
            let scale = 1 / Float(Int16.max)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    let value = buffer.format.isInterleaved ? source[0][frame * channels + channel] : source[channel][frame]
                    sum += Float(value) * scale
                }
                destination[frame] = sum / Float(channels)
            }
        } else {
            throw ResamplerError.unsupportedFormat(buffer.format.description)
        }
        return output
    }
}

public enum ResamplerError: Error, LocalizedError {
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): "Can't convert audio in format \(format)."
        }
    }
}

/// Reads an audio file as 16 kHz mono chunks, for `mmm transcribe`. Nothing is written back.
public final class AudioFileReader {
    public let duration: TimeInterval
    private let file: AVAudioFile
    private let resampler: Resampler
    private let buffer: AVAudioPCMBuffer
    private var produced = 0

    public init(url: URL, chunkSeconds: Double = 0.5) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        duration = Double(file.length) / file.processingFormat.sampleRate
        resampler = try Resampler(inputFormat: file.processingFormat)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * chunkSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw ResamplerError.unsupportedFormat(file.processingFormat.description)
        }
        self.buffer = buffer
    }

    /// The next chunk, timed from the start of the file; nil at the end.
    public func next() throws -> AudioChunk? {
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            if buffer.frameLength == 0 { return nil }
            let samples = try resampler.convert(buffer)
            if samples.isEmpty { continue }
            defer { produced += samples.count }
            return AudioChunk(samples: samples, time: Double(produced) / AudioChunk.samplesPerSecond)
        }
        return nil
    }
}
