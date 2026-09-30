import Foundation
import UniformTypeIdentifiers

/// Finding a recording to transcribe: in what a terminal types when a file is dropped on its
/// window, or with the Mac's own Open window.
enum Recordings {
    /// Extensions of recordings AVFoundation reads, including some the system's file types don't
    /// cover (Voice Memos' .qta, say).
    static let extensions: Set<String> = [
        "m4a", "qta", "mp3", "wav", "wave", "aif", "aiff", "aifc", "caf", "aac", "flac", "amr", "3gp", "mp4", "m4v",
        "mov",
    ]

    /// The recording named in pasted text, if it's an existing sound or video file. A file dropped
    /// on a terminal window arrives as its path: as is, with spaces and other characters escaped
    /// by backslashes, in quotes, or as a file:// URL.
    static func url(fromPasted text: String) -> URL? {
        files(inPasted: text).first(where: isRecording)
    }

    /// Existing files named in pasted text, recordings or not.
    static func files(inPasted text: String) -> [URL] {
        paths(in: text).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }.filter { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
        }
    }

    /// Every reading of pasted text as paths, most literal first.
    static func paths(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var paths = [trimmed]  // a path pasted as is, spaces and all
        var current = ""
        var quote: Character?
        var escaped = false
        func finish() {
            if !current.isEmpty { paths.append(current) }
            current = ""
        }
        for char in trimmed {
            if escaped {
                current.append(char)
                escaped = false
            } else if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
            } else if char == "\\" {
                escaped = true
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char.isWhitespace {
                finish()
            } else {
                current.append(char)
            }
        }
        finish()
        return paths.flatMap { path -> [String] in
            guard path.hasPrefix("file://") else { return [path] }
            return URL(string: path).map { [$0.path] } ?? []
        }
    }

    /// Whether a file looks like audio or video, by its name.
    static func isRecording(_ url: URL) -> Bool {
        let type = url.pathExtension.lowercased()
        return extensions.contains(type) || UTType(filenameExtension: type)?.conforms(to: .audiovisualContent) == true
    }

    /// Shows the Mac's Open window for choosing a recording; nil if none was chosen.
    static func choose() async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: runOpenWindow()) }
        }
    }

    /// AppleScript's `choose file` puts up the standard Open window, from the terminal, with no
    /// permission needed. Returns nil when it's cancelled.
    private static func runOpenWindow() -> URL? {
        let prompt =
            "Choose a recording to transcribe. For a voice memo, first drag it from Voice Memos to your desktop."
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "activate",
            "-e", "set chosen to choose file with prompt \"\(prompt)\" of type {\"public.audiovisual-content\"}",
            "-e", "POSIX path of chosen",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
