import Foundation
import Testing

/// Guards the promise that audio is never written to disk. Audio lives only in memory: the
/// capture buffers, the stretch held for speaker analysis (at most 30 s a channel) and the
/// visualizers' last fraction of a second. FluidAudio's file-based entry points spill audio into
/// temporary files, so only its in-memory ones may be used.
@Suite struct NoAudioOnDiskTests {
    @Test func sourcesNeverWriteAudio() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources")
        let forbidden = [
            "AVAudioFile(forWriting", "ExtAudioFileCreate", "AudioFileCreate", "transcribeDiskBacked", "makeDiskBackedSource",
            "AudioSourceFactory", "embeddingExportPath", "process(url", "transcribe(url",
        ]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 20)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                #expect(!text.contains(word), "\(file.lastPathComponent) uses \(word)")
            }
        }
    }
}
