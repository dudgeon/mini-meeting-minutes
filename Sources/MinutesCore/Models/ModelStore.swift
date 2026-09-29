import CryptoKit
import Foundation

public enum ModelStoreError: Error, LocalizedError {
    case notFound([URL])
    case missingPart(String)
    case checksumMismatch(String)
    case sizeMismatch(String, expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .notFound(let candidates):
            "Couldn't find the vendored models (Models/manifest.json). Looked in:\n"
                + candidates.map { "  \($0.path)" }.joined(separator: "\n")
                + "\nRun mmm from its checkout, or set MMM_MODELS_DIR to the Models directory."
        case .missingPart(let path):
            "Model part \(path) is missing. Is the checkout complete?"
        case .checksumMismatch(let path):
            "\(path) doesn't match its recorded SHA-256. Re-clone the repository or rerun scripts/vendor_models.py."
        case .sizeMismatch(let path, let expected, let actual):
            "\(path) is \(actual) bytes; expected \(expected)."
        }
    }
}

/// The vendored model directory (`Models/` in the repository).
///
/// GitHub rejects files over 100 MiB, so `scripts/vendor_models.py` splits large weight files into
/// numbered parts. `prepare()` joins them back together on first run and checks the SHA-256
/// recorded in `manifest.json`.
public struct ModelStore: Sendable {
    public let root: URL
    let manifest: Manifest

    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let path: String
            let size: Int
            let sha256: String
            let parts: [String]?
        }

        struct Source: Decodable, Sendable {
            let name: String
            let purpose: String
            let repo: String
            let revision: String
            let license: String
        }

        let formatVersion: Int
        let sources: [Source]
        let files: [File]
    }

    public init(root: URL) throws {
        self.root = root
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        self.manifest = try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// `MMM_MODELS_DIR` when set; otherwise the `Models/` directory of the checkout this binary
    /// was built from.
    public static func locate() throws -> ModelStore {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["MMM_MODELS_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        // This file lives at <checkout>/Sources/MinutesCore/Models/ModelStore.swift.
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(checkout.appendingPathComponent("Models", isDirectory: true))

        for candidate in candidates
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
            return try ModelStore(root: candidate)
        }
        throw ModelStoreError.notFound(candidates)
    }

    public func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Model sources and licenses, for `mmm doctor` and attribution.
    public var sources: [(name: String, repo: String, revision: String, license: String)] {
        manifest.sources.map { ($0.name, $0.repo, $0.revision, $0.license) }
    }

    /// Reassembles split files that aren't on disk yet. Cheap when there's nothing to do.
    public func prepare(progress: (String) -> Void = { _ in }) throws {
        for file in manifest.files {
            guard let parts = file.parts else { continue }
            let target = url(file.path)
            if let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == file.size {
                continue
            }
            progress("Reassembling \(file.path) from \(parts.count) parts")
            try reassemble(file, parts: parts, into: target)
        }
    }

    /// Checks every vendored file (or its parts) against the manifest. Returns problems found.
    public func verify() -> [String] {
        var problems: [String] = []
        for file in manifest.files {
            do {
                var hasher = SHA256()
                var size = 0
                let pieces = file.parts ?? [file.path]
                for piece in pieces {
                    let handle = try FileHandle(forReadingFrom: url(piece))
                    defer { try? handle.close() }
                    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
                        hasher.update(data: block)
                        size += block.count
                    }
                }
                if size != file.size {
                    problems.append("\(file.path): \(size) bytes, expected \(file.size)")
                } else if hasher.finalize().hexString != file.sha256 {
                    problems.append("\(file.path): SHA-256 mismatch")
                }
            } catch {
                problems.append("\(file.path): \(error.localizedDescription)")
            }
        }
        return problems
    }

    private func reassemble(_ file: Manifest.File, parts: [String], into target: URL) throws {
        let fileManager = FileManager.default
        let temporary = target.appendingPathExtension("reassembling")
        try? fileManager.removeItem(at: temporary)
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        let output = try FileHandle(forWritingTo: temporary)
        var hasher = SHA256()
        var size = 0
        do {
            for part in parts {
                let partURL = url(part)
                guard fileManager.fileExists(atPath: partURL.path) else { throw ModelStoreError.missingPart(part) }
                let data = try Data(contentsOf: partURL, options: .alwaysMapped)
                hasher.update(data: data)
                try output.write(contentsOf: data)
                size += data.count
            }
            try output.close()
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        guard size == file.size else {
            try? fileManager.removeItem(at: temporary)
            throw ModelStoreError.sizeMismatch(file.path, expected: file.size, actual: size)
        }
        guard hasher.finalize().hexString == file.sha256 else {
            try? fileManager.removeItem(at: temporary)
            throw ModelStoreError.checksumMismatch(file.path)
        }
        _ = try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: temporary, to: target)
    }
}

extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
