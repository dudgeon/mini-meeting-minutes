import FluidAudio
import Foundation

/// Runs a meeting: routes captured audio through echo cancellation and the per-channel pipelines,
/// collects attributed turns, and relabels speakers across the whole meeting when it ends.
public actor MeetingSession {
    public struct Configuration: Sendable {
        public var channels: Set<Channel>
        /// Cancel remote audio that leaks from the speakers into the microphone. Needs both channels.
        public var echoCancellation: Bool
        /// Categories to redact; empty turns redaction off.
        public var redaction: Set<PIICategory>
        public var pipeline: PipelineSettings

        public init(
            channels: Set<Channel> = Set(Channel.allCases), echoCancellation: Bool = true,
            redaction: Set<PIICategory> = Set(PIICategory.allCases), pipeline: PipelineSettings = PipelineSettings()
        ) {
            self.channels = channels
            self.echoCancellation = echoCancellation
            self.redaction = redaction
            self.pipeline = pipeline
        }
    }

    public nonisolated let updates: AsyncStream<ChannelUpdate>
    private let continuation: AsyncStream<ChannelUpdate>.Continuation
    private var pipelines: [Channel: ChannelPipeline] = [:]
    private let echo: EchoCanceller?
    private var turns: [Turn] = []

    public init(models: LoadedModels, configuration: Configuration) async throws {
        (updates, continuation) = AsyncStream.makeStream(of: ChannelUpdate.self)
        let asr = AsrManager(config: .default, models: models.asr)
        let vad = VadManager(
            config: VadConfig(defaultThreshold: configuration.pipeline.vadThreshold), vadModel: models.vad)
        let redactor = configuration.redaction.isEmpty ? nil : PIIRedactor(categories: configuration.redaction)
        let embedder = try SpeakerEmbedder(models: models.diarizer)
        for channel in configuration.channels.sorted() {
            pipelines[channel] = await ChannelPipeline(
                channel: channel, settings: configuration.pipeline, asr: asr,
                decoderLayers: models.asrVersion.decoderLayers, vad: vad, diarizer: models.diarizer,
                embedder: embedder, redactor: redactor)
        }
        if configuration.echoCancellation && configuration.channels == Set(Channel.allCases) {
            echo = try await EchoCanceller(model: models.echoCanceller)
        } else {
            echo = nil
        }
    }

    public var echoCancellationEnabled: Bool { echo != nil }

    /// Feeds captured audio. Call from one task, in capture order.
    public func ingest(_ channel: Channel, _ chunk: AudioChunk) async throws {
        switch channel {
        case .remote:
            await echo?.addReference(chunk)
            try await route(.remote, chunk)
            if let echo {
                for enhanced in try await echo.drainAvailable() { try await route(.room, enhanced) }
            }
        case .room:
            if let echo {
                for enhanced in try await echo.process(chunk) { try await route(.room, enhanced) }
            } else {
                try await route(.room, chunk)
            }
        }
    }

    /// Transcribes whatever is still buffered and returns the meeting's turns in order, with
    /// speakers relabeled using the whole meeting.
    public func finish() async throws -> [Turn] {
        if let echo {
            for enhanced in try await echo.finish() { try await route(.room, enhanced) }
        }
        var labels: [SegmentKey: SpeakerID] = [:]
        for channel in pipelines.keys.sorted() {
            guard let pipeline = pipelines[channel] else { continue }
            publish(try await pipeline.flush())
            labels.merge(await pipeline.finalAssignment()) { current, _ in current }
        }
        for index in turns.indices {
            if let label = labels[turns[index].origin] { turns[index].speaker = label }
        }
        continuation.finish()
        return turns.sorted { $0.start < $1.start }
    }

    /// Turns attributed so far, with live speaker labels.
    public var currentTurns: [Turn] { turns.sorted { $0.start < $1.start } }

    private func route(_ channel: Channel, _ chunk: AudioChunk) async throws {
        guard let pipeline = pipelines[channel] else { return }
        publish(try await pipeline.ingest(chunk))
    }

    private func publish(_ updates: [ChannelUpdate]) {
        for update in updates {
            if case .turns(let new) = update { turns += new }
            continuation.yield(update)
        }
    }
}
