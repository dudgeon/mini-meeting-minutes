@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Removes remote participants' voices from the microphone when they play through the laptop's
/// speakers, using LocalVQE with the captured system audio as the far-end reference.
///
/// Microphone audio is held until the matching stretch of system audio has arrived (at most
/// `maxWait`), then enhanced. Output samples line up one-to-one with input samples, so the
/// enhanced stream keeps the microphone's timestamps.
actor EchoCanceller {
    private let manager: LocalVqeManager
    private var stream: LocalVqeStream
    private let maxWait: TimeInterval = 0.5

    private var reference: [Float] = []
    private var referenceStart: TimeInterval?

    private var mic: [Float] = []
    private var micStart: TimeInterval?
    private var outputTime: TimeInterval?

    init(model: MLModel) async throws {
        let config = LocalVqeConfig(variant: .v13, chunk: .batch256ms, computeUnits: .cpuOnly)
        manager = LocalVqeManager(config: config, model: model)
        stream = try await manager.makeStream()
    }

    func addReference(_ chunk: AudioChunk) {
        guard let start = referenceStart else {
            referenceStart = chunk.time
            reference = chunk.samples
            return
        }
        let gap = chunk.time - (start + Double(reference.count) / AudioChunk.samplesPerSecond)
        if gap < -0.5 || gap > 10 {
            referenceStart = chunk.time
            reference = chunk.samples
            return
        }
        if gap > 0.02 {
            reference += [Float](repeating: 0, count: Int(gap * AudioChunk.samplesPerSecond))
        }
        reference += chunk.samples
        // Never hold more than 30 s of far-end audio, even if the microphone stalls.
        let limit = 30 * AudioChunk.sampleRate
        if reference.count > limit {
            let excess = reference.count - limit
            reference.removeFirst(excess)
            referenceStart = start + Double(excess) / AudioChunk.samplesPerSecond
        }
    }

    /// Queues microphone audio and returns whatever can be enhanced now.
    func process(_ chunk: AudioChunk) async throws -> [AudioChunk] {
        var output: [AudioChunk] = []
        if let start = micStart {
            let gap = chunk.time - (start + Double(mic.count) / AudioChunk.samplesPerSecond)
            if gap > 10 || gap < -1 {
                output += try await finish()
            } else if gap > 0.02 {
                mic += [Float](repeating: 0, count: Int(gap * AudioChunk.samplesPerSecond))
            }
        }
        if micStart == nil { micStart = chunk.time }
        mic += chunk.samples
        output += try await drain(force: false)
        return output
    }

    /// Enhances microphone audio that was waiting for reference audio that has now arrived.
    func drainAvailable() async throws -> [AudioChunk] {
        try await drain(force: false)
    }

    /// Enhances everything queued and resets for a new stretch of audio.
    func finish() async throws -> [AudioChunk] {
        var output = try await drain(force: true)
        let tail = try await stream.flush()
        if !tail.isEmpty, let time = outputTime {
            output.append(AudioChunk(samples: tail, time: time))
        }
        mic.removeAll()
        micStart = nil
        outputTime = nil
        return output
    }

    private func drain(force: Bool) async throws -> [AudioChunk] {
        guard let start = micStart, !mic.isEmpty else { return [] }
        let micEnd = start + Double(mic.count) / AudioChunk.samplesPerSecond
        let referenceEnd = referenceStart.map { $0 + Double(reference.count) / AudioChunk.samplesPerSecond }
        let limit = force ? micEnd : max(min(referenceEnd ?? -.infinity, micEnd), micEnd - maxWait)
        let count = min(Int((limit - start) * AudioChunk.samplesPerSecond), mic.count)
        guard count > 0 else { return [] }

        let input = Array(mic.prefix(count))
        mic.removeFirst(count)
        micStart = start + Double(count) / AudioChunk.samplesPerSecond
        let far = takeReference(from: start, count: count)

        if outputTime == nil { outputTime = start }
        let enhanced = try await stream.enhance(mic: input, reference: far)
        guard !enhanced.isEmpty, let time = outputTime else { return [] }
        outputTime = time + Double(enhanced.count) / AudioChunk.samplesPerSecond
        return [AudioChunk(samples: enhanced, time: time)]
    }

    /// Reference samples covering [time, time + count), silence where none was captured. Drops
    /// reference audio older than `time`.
    private func takeReference(from time: TimeInterval, count: Int) -> [Float] {
        guard let start = referenceStart else { return [Float](repeating: 0, count: count) }
        let offset = Int(((time - start) * AudioChunk.samplesPerSecond).rounded())
        var slice = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let source = offset + index
            if source >= 0 && source < reference.count { slice[index] = reference[source] }
        }
        let consumed = min(max(offset + count, 0), reference.count)
        if consumed > 0 {
            reference.removeFirst(consumed)
            referenceStart = start + Double(consumed) / AudioChunk.samplesPerSecond
        }
        return slice
    }
}
