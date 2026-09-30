import CryptoKit
import Foundation
import Testing

@testable import MinutesCore

@Suite struct ModelStoreTests {
    /// A throwaway models directory with one file split into three parts.
    func makeStore(corruptPart: Bool = false) throws -> (store: ModelStore, payload: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mmm-store-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("model/weights")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let parts = [payload[0..<4_000], payload[4_000..<8_000], payload[8_000...]]
        for (index, part) in parts.enumerated() {
            var bytes = Data(part)
            if corruptPart && index == 1 { bytes[bytes.startIndex] ^= 0xFF }
            try bytes.write(to: directory.appendingPathComponent("weight.bin.part-00\(index)"))
        }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = """
            {"formatVersion": 1, "sources": [],
             "files": [{"path": "model/weights/weight.bin", "size": \(payload.count), "sha256": "\(digest)",
                        "parts": ["model/weights/weight.bin.part-000", "model/weights/weight.bin.part-001",
                                  "model/weights/weight.bin.part-002"]}]}
            """
        try manifest.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return (try ModelStore(root: root), payload)
    }

    @Test func reassemblesSplitFiles() throws {
        let (store, payload) = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepare()
        #expect(try Data(contentsOf: store.url("model/weights/weight.bin")) == payload)
        #expect(store.verify().isEmpty)
        try store.prepare()  // idempotent
    }

    @Test func joinsAgainWhenTheModelIsUpdated() throws {
        let (store, payload) = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepare()

        // An update brings new weights of the same size: new parts, a new checksum.
        let updated = Data(payload.reversed())
        let parts = [updated[0..<4_000], updated[4_000..<8_000], updated[8_000...]]
        for (index, part) in parts.enumerated() {
            try Data(part).write(to: store.url("model/weights/weight.bin.part-00\(index)"))
        }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let manifestURL = store.root.appendingPathComponent("manifest.json")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: digest(payload), with: digest(updated))
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let newer = try ModelStore(root: store.root)
        #expect(!newer.verify().isEmpty)  // the old joined file no longer matches...
        try newer.prepare()  // ...so it's joined again
        #expect(try Data(contentsOf: newer.url("model/weights/weight.bin")) == updated)
        #expect(newer.verify().isEmpty)
    }

    @Test func rejectsCorruptParts() throws {
        let (store, _) = try makeStore(corruptPart: true)
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(throws: ModelStoreError.self) { try store.prepare() }
        #expect(!FileManager.default.fileExists(atPath: store.url("model/weights/weight.bin").path))
        #expect(!store.verify().isEmpty)
    }

    @Test func vendoredModelsAreComplete() throws {
        let store = try ModelStore.locate()
        try store.prepare()
        #expect(store.verify().isEmpty)
    }
}
