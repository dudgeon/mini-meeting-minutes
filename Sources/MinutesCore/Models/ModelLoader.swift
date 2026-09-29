@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Every model the pipeline uses, loaded from the vendored `Models/` directory.
public struct LoadedModels: Sendable {
    public let asr: AsrModels
    public let asrVersion: AsrModelVersion
    public let vad: MLModel
    public let diarizer: OfflineDiarizerModels
    public let echoCanceller: MLModel
}

public enum ModelLoader {
    static let asrDirectory = "parakeet-redux"
    static let diarizerDirectory = "speaker-diarization"
    static let vadModel = "silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc"
    static let echoModel = "localvqe/localvqe-v1.3-4.8M-256ms.mlmodelc"

    /// Loads all models. Never touches the network: FluidAudio's downloader is switched off first.
    public static func load(from store: ModelStore, progress: (String) -> Void = { _ in }) throws -> LoadedModels {
        ModelHub.offlineMode = true
        try store.prepare(progress: progress)

        progress("Loading speech recognizer")
        // The GPU decompresses Redux's 2-bit weights in-kernel and loads in about a second; the
        // Neural Engine would first spend several minutes compiling them.
        let asr = try AsrModels.loadLocal(
            from: store.url(asrDirectory), version: .redux, encoderComputeUnits: .cpuAndGPU)

        progress("Loading voice activity detector")
        let vad = try MLModel(
            contentsOf: store.url(vadModel), configuration: configuration(.cpuAndNeuralEngine))

        progress("Loading speaker diarizer")
        let diarizerRoot = store.url(diarizerDirectory)
        let diarizer = OfflineDiarizerModels(
            segmentationModel: try MLModel(
                contentsOf: diarizerRoot.appendingPathComponent("Segmentation.mlmodelc"),
                configuration: configuration(.all)),
            fbankModel: try MLModel(
                contentsOf: diarizerRoot.appendingPathComponent("FBank.mlmodelc"),
                configuration: configuration(.cpuOnly)),
            embeddingModel: try MLModel(
                contentsOf: diarizerRoot.appendingPathComponent("Embedding.mlmodelc"),
                configuration: configuration(.all)),
            pldaRhoModel: try MLModel(
                contentsOf: diarizerRoot.appendingPathComponent("PldaRho.mlmodelc"),
                configuration: configuration(.all)),
            pldaPsi: try loadPldaPsi(diarizerRoot.appendingPathComponent("plda-parameters.json")),
            compilationDuration: 0)

        progress("Loading echo canceller")
        // LocalVQE ships fp32 weights; the CPU is fastest for it.
        let echo = try MLModel(contentsOf: store.url(echoModel), configuration: configuration(.cpuOnly))

        return LoadedModels(asr: asr, asrVersion: .redux, vad: vad, diarizer: diarizer, echoCanceller: echo)
    }

    private static func configuration(_ units: MLComputeUnits) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return configuration
    }

    /// Reads the PLDA `psi` vector the same way FluidAudio's own loader does.
    static func loadPldaPsi(_ url: URL) throws -> [Double] {
        let data = try Data(contentsOf: url)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any],
            let base64 = psi["data_base64"] as? String,
            let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
            decoded.count >= MemoryLayout<Float>.size
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        var floats = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}
