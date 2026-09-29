@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Turns a stretch of one person's speech into a 256-dimension WeSpeaker voice embedding, using
/// the same FBank and embedding models as the community-1 diarizer (compare FluidAudio's internal
/// `OfflineEmbeddingExtractor.embedSpan`).
///
/// Core ML predictions are thread-safe, so one embedder can serve several pipelines.
public final class SpeakerEmbedder: @unchecked Sendable {
    public static let dimension = 256

    private let fbank: MLModel
    private let embedding: MLModel
    private let audioShape: [NSNumber]
    private let audioCount: Int
    private let weightShape: [NSNumber]
    private let weightCount: Int

    public init(models: OfflineDiarizerModels) throws {
        fbank = models.fbankModel
        embedding = models.embeddingModel
        guard
            let audio = fbank.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint,
            let weights = embedding.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint
        else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Unexpected embedding model inputs"])
        }
        audioShape = audio.shape
        audioCount = audio.shape.reduce(1) { $0 * $1.intValue }
        weightShape = weights.shape
        weightCount = weights.shape.reduce(1) { $0 * $1.intValue }
    }

    /// Longest span one call can embed.
    public var maxSamples: Int { audioCount }

    /// Embeds up to `maxSamples` samples of 16 kHz audio; longer input is truncated.
    ///
    /// Shorter input is repeated to fill the model's window rather than zero-padded: the
    /// filterbank front end normalizes over the whole window, so padding with silence would make
    /// the embedding depend on the clip's length instead of the voice.
    public func embed(_ samples: ArraySlice<Float>) throws -> [Float] {
        let count = min(samples.count, audioCount)
        guard count > 0 else { return [] }

        let audio = try MLMultiArray(shape: audioShape, dataType: .float32)
        let audioPointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
        samples.prefix(count).withUnsafeBufferPointer { source in
            var filled = 0
            while filled < audioCount {
                let run = min(count, audioCount - filled)
                (audioPointer + filled).update(from: source.baseAddress!, count: run)
                filled += run
            }
        }
        let features = try fbank.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audio]))
        guard let fbankFeatures = features.featureValue(for: "fbank_features") else { return [] }

        let weights = try MLMultiArray(shape: weightShape, dataType: .float32)
        let weightPointer = weights.dataPointer.assumingMemoryBound(to: Float.self)
        weightPointer.update(repeating: 1, count: weightCount)

        let output = try embedding.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "fbank_features": fbankFeatures, "weights": MLFeatureValue(multiArray: weights),
            ]))
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue else { return [] }
        let pointer = vector.dataPointer.assumingMemoryBound(to: Float.self)
        let values = Array(UnsafeBufferPointer(start: pointer, count: vector.count))
        return values.contains { !$0.isFinite } ? [] : values
    }
}
