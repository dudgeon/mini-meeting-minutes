import FluidAudio
import Foundation

/// Tunables for turning one channel's audio into attributed turns.
public struct PipelineSettings: Sendable {
    /// A diarization window closes at the first pause after this much audio...
    public var targetWindowSeconds: Double = 30
    /// ...or here, even mid-sentence.
    public var maxWindowSeconds: Double = 60
    /// A window also closes after this much silence, so labels don't lag behind a pause.
    public var idleFlushSeconds: Double = 3
    /// Longest stretch sent to the recognizer at once (its encoder sees 15 s).
    public var maxUtteranceSeconds: Double = 14
    /// Diarized stretches longer than this are split before embedding (the model sees 10 s).
    public var maxSegmentSeconds: Double = 8
    /// Shorter segments get no embedding of their own; they follow the diarizer's grouping.
    public var minEmbeddingSeconds: Double = 0.5
    /// Speech probability that starts an utterance (Silero VAD).
    public var vadThreshold: Float = 0.6
    /// Silence that ends an utterance. FluidAudio's streaming VAD measures it from the end of the
    /// first quiet 256 ms chunk, so the pause actually needed is about 0.25 s longer.
    public var minSilenceSeconds: Double = 0.3
    public var speakerThresholds = SpeakerLinker.Thresholds()

    public init() {}
}

/// What a channel reports back after ingesting audio.
public enum ChannelUpdate: Sendable {
    /// Recognized text not yet attributed to a speaker (already redacted).
    case pending(Channel, String)
    /// Newly attributed turns.
    case turns([Turn])
    /// Seconds of this channel's audio currently held in memory, waiting to be diarized.
    case buffered(Channel, TimeInterval)
}

/// Transcribes and diarizes one channel.
///
/// Audio flows through voice activity detection, which cuts it into utterances for the
/// recognizer. The same audio accumulates into a diarization window of 30–60 s. When a window
/// closes it is diarized, its words are attributed to speakers, and the window's audio is
/// released. Only words (until attributed) and voice embeddings outlive the window.
actor ChannelPipeline {
    let channel: Channel
    private let settings: PipelineSettings
    private let asr: AsrManager
    private let decoderLayers: Int
    private let vad: VadManager
    private let segmentation: VadSegmentationConfig
    private let diarizer: OfflineDiarizerModels
    private let embedder: SpeakerEmbedder
    private let redactor: PIIRedactor?
    private var linker: SpeakerLinker

    private var anchorTime: TimeInterval?  // session time of stream sample 0
    private var received = 0  // stream samples received

    private var vadState: VadStreamState
    private var vadOrigin = 0  // stream sample where the current VAD state started
    private var vadPosition = 0  // stream samples the VAD has consumed
    private var vadBuffer: [Float] = []

    private var window: [Float] = []
    private var windowStart = 0  // stream sample index of window[0]
    private var windowIndex = 0

    private var speechStart: Int?
    private var lastSpeechEnd: Int?
    private var pendingWords: [Word] = []

    init(
        channel: Channel, settings: PipelineSettings, asr: AsrManager, decoderLayers: Int, vad: VadManager,
        diarizer: OfflineDiarizerModels, embedder: SpeakerEmbedder, redactor: PIIRedactor?
    ) async {
        self.channel = channel
        self.settings = settings
        self.asr = asr
        self.decoderLayers = decoderLayers
        self.vad = vad
        self.diarizer = diarizer
        self.embedder = embedder
        self.redactor = redactor
        self.linker = SpeakerLinker(channel: channel, thresholds: settings.speakerThresholds)
        self.segmentation = VadSegmentationConfig(
            minSpeechDuration: 0.15, minSilenceDuration: settings.minSilenceSeconds,
            maxSpeechDuration: settings.maxUtteranceSeconds, speechPadding: 0.15,
            negativeThresholdOffset: 0.15)
        self.vadState = await vad.makeStreamState()
    }

    private static let rate = AudioChunk.sampleRate
    private static let debug = ProcessInfo.processInfo.environment["MMM_DEBUG"] != nil

    /// Diagnostics on stderr when MMM_DEBUG is set. Never includes audio; may include text.
    private func log(_ message: @autoclosure () -> String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(Data("[\(channel.rawValue)] \(message())\n".utf8))
    }

    private func time(ofSample sample: Int) -> TimeInterval {
        (anchorTime ?? 0) + Double(sample) / AudioChunk.samplesPerSecond
    }

    // MARK: - Ingest

    func ingest(_ chunk: AudioChunk) async throws -> [ChannelUpdate] {
        guard !chunk.samples.isEmpty else { return [] }
        var updates: [ChannelUpdate] = []
        if anchorTime == nil { anchorTime = chunk.time }

        let gap = chunk.time - time(ofSample: received)
        if gap > 10 || gap < -1 {
            // A pause or clock jump: finish what we have and restart the clock at this chunk.
            updates += try await flush()
            anchorTime = chunk.time - Double(received) / AudioChunk.samplesPerSecond
        } else if gap > 0.1 {
            // Dropped audio: fill with silence so sample counts keep matching the clock.
            updates += try await append([Float](repeating: 0, count: Int(gap * AudioChunk.samplesPerSecond)))
        }
        updates += try await append(chunk.samples)
        updates.append(.buffered(channel, Double(window.count) / AudioChunk.samplesPerSecond))
        return updates
    }

    /// Transcribes and attributes everything buffered, e.g. at the end of the meeting.
    func flush() async throws -> [ChannelUpdate] {
        var updates: [ChannelUpdate] = []
        if !vadBuffer.isEmpty {
            let block = vadBuffer + [Float](repeating: 0, count: VadManager.chunkSize - vadBuffer.count)
            vadBuffer.removeAll()
            updates += try await runVAD(block)
        }
        if let start = speechStart {
            updates += try await transcribe(start..<received)
            speechStart = nil
        }
        updates += try await closeWindow(at: received)
        vadState = await vad.makeStreamState()
        vadOrigin = received
        vadPosition = received
        lastSpeechEnd = nil
        updates.append(.buffered(channel, Double(window.count) / AudioChunk.samplesPerSecond))
        return updates
    }

    /// Final meeting-wide speaker labels, after all audio has been flushed.
    func finalAssignment() -> [SegmentKey: SpeakerID] {
        linker.finalAssignment()
    }

    private func append(_ samples: [Float]) async throws -> [ChannelUpdate] {
        var updates: [ChannelUpdate] = []
        window.append(contentsOf: samples)
        vadBuffer.append(contentsOf: samples)
        received += samples.count
        while vadBuffer.count >= VadManager.chunkSize {
            let block = Array(vadBuffer.prefix(VadManager.chunkSize))
            vadBuffer.removeFirst(VadManager.chunkSize)
            updates += try await runVAD(block)
        }
        return updates
    }

    private func runVAD(_ block: [Float]) async throws -> [ChannelUpdate] {
        let result = try await vad.processStreamingChunk(
            block, state: vadState, config: segmentation, returnSeconds: false, timeResolution: 1)
        vadState = result.state
        vadPosition += block.count

        var updates: [ChannelUpdate] = []
        if let event = result.event {
            let sample = vadOrigin + event.sampleIndex
            switch event.kind {
            case .speechStart:
                speechStart = max(sample, windowStart)
            case .speechEnd:
                if let start = speechStart {
                    updates += try await transcribe(start..<max(start, min(sample, received)))
                }
                speechStart = nil
                lastSpeechEnd = min(sample, received)
            }
        }

        let maxUtterance = Int(settings.maxUtteranceSeconds * AudioChunk.samplesPerSecond)
        if let start = speechStart, vadPosition - start >= maxUtterance {
            // Too long for one recognizer pass: split at the quietest moment of the last few
            // seconds rather than mid-word.
            let end = min(vadPosition, received)
            let cut = quietestPoint(in: max(start + Self.rate * 6, end - Self.rate * 4)..<end)
            updates += try await transcribe(start..<cut)
            speechStart = cut
        }
        updates += try await closeWindowIfDue()
        return updates
    }

    // MARK: - Recognition

    private func transcribe(_ range: Range<Int>) async throws -> [ChannelUpdate] {
        let lower = max(range.lowerBound, windowStart)
        let upper = min(range.upperBound, windowStart + window.count)
        // Skip clicks and breaths the VAD let through.
        guard upper - lower >= Self.rate / 5 else { return [] }

        var samples = Array(window[(lower - windowStart)..<(upper - windowStart)])
        let minimum = Self.rate * 3 / 10  // the recognizer rejects anything under 0.3 s
        if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }

        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(samples, decoderState: &state)
        let words = Self.words(from: result.tokenTimings ?? [], offset: time(ofSample: lower))
        log(String(format: "utterance %.2f–%.2f: %@", time(ofSample: lower), time(ofSample: upper), words.joinedText))
        guard !words.isEmpty else { return [] }
        pendingWords += words
        return [.pending(channel, pendingText)]
    }

    private var pendingText: String {
        let text = pendingWords.joinedText
        return redactor?.redact(text) ?? text
    }

    /// Groups sentencepiece tokens into words, carrying timing and mean confidence.
    static func words(from tokens: [TokenTiming], offset: TimeInterval) -> [Word] {
        var words: [Word] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidence: Float = 0
        var count = 0

        func finishWord() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                words.append(
                    Word(
                        text: trimmed, start: offset + start, end: offset + end,
                        confidence: count > 0 ? confidence / Float(count) : 0))
            }
            text = ""
            confidence = 0
            count = 0
        }

        for token in tokens {
            let piece = token.token
            if piece.isEmpty || piece == "<blank>" || piece == "<pad>" || piece.hasPrefix("<|") { continue }
            let beginsWord = piece.hasPrefix("▁") || piece.hasPrefix(" ")
            if beginsWord || text.isEmpty {
                finishWord()
                text = String(piece.drop { $0 == "▁" || $0 == " " })
                start = token.startTime
            } else {
                text += piece
            }
            end = token.endTime
            confidence += token.confidence
            count += 1
        }
        finishWord()
        return words
    }

    // MARK: - Diarization windows

    private func closeWindowIfDue() async throws -> [ChannelUpdate] {
        let length = Double(vadPosition - windowStart) / AudioChunk.samplesPerSecond
        guard let start = speechStart else {
            if pendingWords.isEmpty {
                // Nothing said since the last window: release the silence rather than hold it,
                // keeping a second for the VAD's look-back padding.
                let keep = Self.rate
                let drop = min(vadPosition - windowStart - keep, window.count)
                if drop > Self.rate {
                    window.removeFirst(drop)
                    windowStart += drop
                }
                return []
            }
            let silence = lastSpeechEnd.map { Double(vadPosition - $0) / AudioChunk.samplesPerSecond } ?? 0
            if length >= settings.targetWindowSeconds || silence >= settings.idleFlushSeconds {
                return try await closeWindow(at: min(vadPosition, received))
            }
            return []
        }
        guard length >= settings.maxWindowSeconds else { return [] }
        let end = min(vadPosition, received)
        let cut = quietestPoint(in: max(start, end - Self.rate * 4)..<end)
        var updates = try await transcribe(start..<cut)
        speechStart = cut
        updates += try await closeWindow(at: cut)
        return updates
    }

    /// The stream sample at the center of the quietest 20 ms frame in `range`, preferring later
    /// frames on ties.
    private func quietestPoint(in range: Range<Int>) -> Int {
        let frame = Self.rate / 50
        let lower = max(range.lowerBound, windowStart)
        let upper = min(range.upperBound, windowStart + window.count)
        guard upper - lower >= frame else { return range.upperBound }
        var best = (sample: upper, energy: Float.infinity)
        var position = lower
        while position + frame <= upper {
            var energy: Float = 0
            for index in (position - windowStart)..<(position - windowStart + frame) {
                energy += window[index] * window[index]
            }
            if energy <= best.energy { best = (position + frame / 2, energy) }
            position += frame
        }
        return best.sample
    }

    private func closeWindow(at cut: Int) async throws -> [ChannelUpdate] {
        let count = min(max(cut - windowStart, 0), window.count)
        let windowTime = time(ofSample: windowStart)
        let cutTime = time(ofSample: windowStart + count)
        let words = pendingWords.filter { $0.midpoint < cutTime }
        pendingWords.removeAll { $0.midpoint < cutTime }

        var audio = Array(window.prefix(count))
        window.removeFirst(count)
        windowStart += count
        defer { audio.removeAll() }
        guard !words.isEmpty else {
            return count > 0 ? [.pending(channel, pendingText)] : []
        }
        defer { windowIndex += 1 }

        // Where each voice speaks, per the diarizer. Long stretches are split so every piece fits
        // the embedding model and a missed speaker change stays local.
        var spans = ((try? await Self.diarize(audio, models: diarizer))?.segments ?? []).map {
            (local: $0.speakerId, start: windowTime + Double($0.startTimeSeconds),
             end: windowTime + Double($0.endTimeSeconds))
        }.sorted { $0.start < $1.start }
        if spans.isEmpty, let first = words.first, let last = words.last {
            // The recognizer heard speech the diarizer didn't: treat it as one speaker.
            spans = [(local: "?", start: first.start, end: last.end)]
        }
        var segments: [Segment] = []
        for span in spans {
            let pieces = max(1, Int(((span.end - span.start) / settings.maxSegmentSeconds).rounded(.up)))
            let step = (span.end - span.start) / Double(pieces)
            for piece in 0..<pieces {
                segments.append(
                    Segment(
                        index: segments.count, speaker: span.local, start: span.start + step * Double(piece),
                        end: span.start + step * Double(piece + 1)))
            }
        }

        // Each segment's own voice embedding decides who it is, across the whole meeting.
        let linked = segments.map { segment in
            SpeakerLinker.Segment(
                index: segment.index, local: segment.speaker, start: segment.start,
                duration: segment.end - segment.start, embedding: embedding(of: segment, in: audio, from: windowTime))
        }
        if Self.debug {
            for segment in linked {
                guard let embedding = segment.embedding else { continue }
                let before = linker.similarities(of: embedding).map { String(format: "%.2f", $0) }
                let within = linked.compactMap { other in other.embedding.map { String(format: "%.2f", SpeakerLinker.dot(SpeakerLinker.normalized(embedding), SpeakerLinker.normalized($0))) } }
                log("  sims seg \(segment.index): clusters [\(before.joined(separator: " "))] window [\(within.joined(separator: " "))]")
            }
        }
        let labels = linker.link(window: windowIndex, segments: linked)
        log(String(format: "window %d %.2f–%.2f", windowIndex, windowTime, cutTime))
        for segment in linked {
            log(
                String(
                    format: "  segment %d %@ %.2f+%.2f %@ -> %@", segment.index, segment.local, segment.start,
                    segment.duration, segment.embedding == nil ? "(no embedding)" : "",
                    labels[segment.index]?.description ?? "?"))
        }

        var turns: [Turn] = []
        var run: [Word] = []
        var runSegment: Int?
        func finishRun() {
            guard let index = runSegment, let first = run.first, let last = run.last, let label = labels[index]
            else { return }
            let text = run.joinedText
            turns.append(
                Turn(
                    channel: channel, speaker: label,
                    origin: SegmentKey(channel: channel, window: windowIndex, segment: index),
                    start: first.start, end: last.end, text: redactor?.redact(text) ?? text))
            run = []
        }
        for (word, index) in zip(words, Self.attribute(words, to: segments)) {
            if index != runSegment {
                finishRun()
                runSegment = index
            }
            run.append(word)
        }
        finishRun()
        return [.turns(turns), .pending(channel, pendingText)]
    }

    struct Segment {
        let index: Int
        let speaker: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private func embedding(of segment: Segment, in audio: [Float], from windowTime: TimeInterval) -> [Float]? {
        let lower = max(0, Int(((segment.start - windowTime) * AudioChunk.samplesPerSecond).rounded()))
        let upper = min(audio.count, Int(((segment.end - windowTime) * AudioChunk.samplesPerSecond).rounded()))
        guard Double(upper - lower) >= settings.minEmbeddingSeconds * AudioChunk.samplesPerSecond else { return nil }
        guard let vector = try? embedder.embed(audio[lower..<upper]), !vector.isEmpty else { return nil }
        return vector
    }

    /// The segment each word belongs to: most overlap, else the nearest segment within 1.5 s,
    /// else the previous word's.
    static func attribute(_ words: [Word], to segments: [Segment]) -> [Int] {
        var result: [Int?] = words.map { word in
            var best: (index: Int, overlap: Double)?
            for segment in segments {
                let overlap = min(word.end, segment.end) - max(word.start, segment.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (segment.index, overlap) }
            }
            if let best { return best.index }
            var nearest: (index: Int, distance: Double)?
            for segment in segments {
                let distance = max(segment.start - word.midpoint, word.midpoint - segment.end, 0)
                if distance < (nearest?.distance ?? 1.5) { nearest = (segment.index, distance) }
            }
            return nearest?.index
        }
        let firstKnown = result.compactMap { $0 }.first ?? segments.first?.index ?? 0
        for index in result.indices where result[index] == nil {
            result[index] = index > 0 ? result[index - 1] : firstKnown
        }
        return result.map { $0 ?? firstKnown }
    }

    /// Runs the offline community-1 pipeline on one window. A manager per call keeps this free of
    /// shared mutable state; the models themselves are shared.
    private static func diarize(_ audio: [Float], models: OfflineDiarizerModels) async throws -> DiarizationResult {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        manager.initialize(models: models)
        return try await manager.process(audio: audio)
    }
}
