@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MinutesCore

/// Recordings in the formats people have, read as 16 kHz mono. The test recordings are made in a
/// folder of their own and removed afterwards.
@Suite struct AudioFileReaderTests {
    /// A tone, `seconds` long at `rate`, in `channels` channels: the first carries it, the others
    /// are silent.
    static func writeTone(to url: URL, rate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(rate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func readAll(_ url: URL) async throws -> (samples: [Float], reader: AudioFileReader) {
        let reader = try await AudioFileReader.open(url, chunkSeconds: 0.25)
        var samples: [Float] = []
        var expected: TimeInterval = 0
        while let chunk = try reader.next() {
            #expect(abs(chunk.time - expected) < 1e-9)  // chunks are timed from the start, gapless
            expected = chunk.endTime
            samples += chunk.samples
        }
        return (samples, reader)
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    @Test func readsVoiceMemoStyleAAC() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mmm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wave = folder.appendingPathComponent("tone.wav")
        try Self.writeTone(to: wave, rate: 48_000, channels: 1, seconds: 3)
        let memo = folder.appendingPathComponent("New Recording.m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", wave.path, memo.path]
        try convert.run()
        convert.waitUntilExit()
        #expect(convert.terminationStatus == 0)

        let (samples, reader) = try await Self.readAll(memo)
        #expect(abs(reader.duration - 3) < 0.05)
        #expect(abs(Double(samples.count) / AudioChunk.samplesPerSecond - 3) < 0.05)
        #expect(reader.date != nil)  // the file's own date, without metadata
        let level = Self.rms(samples[8_000..<40_000])
        #expect(abs(level - 0.5 / Float(2).squareRoot()) < 0.03, "level \(level)")
    }

    @Test func mixesStereoToMono() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mmm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wave = folder.appendingPathComponent("stereo.wav")
        try Self.writeTone(to: wave, rate: 44_100, channels: 2, seconds: 2)
        let (samples, reader) = try await Self.readAll(wave)
        #expect(abs(reader.duration - 2) < 0.01)
        #expect(abs(samples.count - 32_000) <= 16)
        // One channel of two carries the tone: mixed down, it's half as loud.
        let level = Self.rms(samples[4_000..<28_000])
        #expect(abs(level - 0.25 / Float(2).squareRoot()) < 0.02, "level \(level)")
    }

    @Test func saysWhatsWrongWithFilesThatArentRecordings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mmm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.m4a")
        try Data("not audio".utf8).write(to: text)
        await #expect(throws: AudioFileError.self) { try await AudioFileReader.open(text) }
        await #expect(throws: AudioFileError.self) {
            try await AudioFileReader.open(folder.appendingPathComponent("missing.m4a"))
        }
    }
}
