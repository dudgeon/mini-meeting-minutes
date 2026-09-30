@preconcurrency import AVFoundation
import Foundation

/// Reads the sound of a recording as 16 kHz mono chunks: any audio or video file AVFoundation can
/// play, including Voice Memos recordings (.m4a, .qta). The file is only read; nothing is written.
public final class AudioFileReader {
    /// How long the recording is.
    public let duration: TimeInterval
    /// The title stored in the file (Voice Memos keeps the memo's name there), if any.
    public let title: String?
    /// When the recording was made, from its metadata, else when the file was created.
    public let date: Date?

    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    /// Channels in each decoded frame (1 or 2); stereo is mixed down here.
    private let channels: Int
    private let chunkSize: Int
    private var queued: [Float] = []
    private var produced = 0
    private var ended = false

    private init(
        reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, channels: Int, duration: TimeInterval,
        title: String?, date: Date?, chunkSeconds: Double
    ) {
        self.reader = reader
        self.output = output
        self.channels = channels
        self.duration = duration
        self.title = title
        self.date = date
        chunkSize = max(1, Int(chunkSeconds * AudioChunk.samplesPerSecond))
    }

    deinit {
        reader.cancelReading()
    }

    /// Opens a recording for reading, in chunks of `chunkSeconds`.
    public static func open(_ url: URL, chunkSeconds: Double = 0.5) async throws -> AudioFileReader {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioFileError.notARecording(url.lastPathComponent)
        }
        guard !tracks.isEmpty else { throw AudioFileError.noSound(url.lastPathComponent) }

        var sourceChannels = 1
        for track in tracks {
            for format in try await track.load(.formatDescriptions) {
                if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    sourceChannels = max(sourceChannels, Int(description.mChannelsPerFrame))
                }
            }
        }
        let channels = sourceChannels > 1 ? 2 : 1
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: AudioChunk.samplesPerSecond, AVNumberOfChannelsKey: channels,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioFileError.notARecording(url.lastPathComponent) }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map { AudioFileError.failed(url.lastPathComponent, $0) }
                ?? AudioFileError.notARecording(url.lastPathComponent)
        }

        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        var title: String?
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first {
            title = (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var date: Date?
        if let item = try? await asset.load(.creationDate) { date = try? await item.load(.dateValue) }
        if date == nil { date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate }
        return AudioFileReader(
            reader: reader, output: output, channels: channels, duration: duration,
            title: title?.isEmpty == false ? title : nil, date: date, chunkSeconds: chunkSeconds)
    }

    /// The next chunk, timed from the start of the recording; nil at the end.
    public func next() throws -> AudioChunk? {
        while queued.count < chunkSize && !ended {
            guard let buffer = output.copyNextSampleBuffer() else {
                ended = true
                if reader.status == .failed, let error = reader.error { throw error }
                break
            }
            append(buffer)
        }
        guard !queued.isEmpty else { return nil }
        let count = min(chunkSize, queued.count)
        let samples = Array(queued.prefix(count))
        queued.removeFirst(count)
        defer { produced += count }
        return AudioChunk(samples: samples, time: Double(produced) / AudioChunk.samplesPerSecond)
    }

    /// Adds a decoded buffer's samples, mixing stereo down to mono.
    private func append(_ buffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var decoded = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = decoded.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        if channels == 2 {
            queued.reserveCapacity(queued.count + decoded.count / 2)
            var index = 0
            while index + 1 < decoded.count {
                queued.append((decoded[index] + decoded[index + 1]) * 0.5)
                index += 2
            }
        } else {
            queued += decoded
        }
    }
}

public enum AudioFileError: Error, LocalizedError {
    case unreadable(String)
    case notARecording(String)
    case noSound(String)
    case failed(String, any Error)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "“\(name)” can't be opened. Check that it still exists and that you can open it."
        case .notARecording(let name): "“\(name)” isn't a recording this Mac can play."
        case .noSound(let name): "“\(name)” has no sound in it."
        case .failed(let name, let error): "“\(name)” couldn't be read: \(error.localizedDescription)"
        }
    }
}
