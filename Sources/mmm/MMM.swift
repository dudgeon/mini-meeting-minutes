import ArgumentParser
import Foundation
import MinutesCore

@main
struct MMM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mmm",
        abstract: "Local meeting minutes: transcribes your microphone and system audio into speaker-attributed markdown.",
        discussion: """
            Everything runs on this Mac. Audio is processed in memory and never written to disk; only \
            the markdown minutes are saved. There is no summarization: the minutes are what was said.
            """,
        version: "0.1.0",
        subcommands: [Record.self, Transcribe.self, Doctor.self],
        defaultSubcommand: Record.self)
}

/// Options shared by commands that produce minutes.
struct MinutesOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Output file (.md) or directory. Default: ~/Documents/Minutes.")
    var output: String?

    @Option(name: .shortAndLong, help: "Meeting title, used in the file name and heading.")
    var title: String?

    @Option(
        help: ArgumentHelp(
            "What to redact: all, none, or a comma-separated list of name, email, phone, address, id, card, account, ip.",
            valueName: "categories"))
    var redact = "all"

    @Flag(help: "Skip naming speakers when the meeting ends.")
    var noNames = false

    func redactionCategories() throws -> Set<PIICategory> {
        switch redact.lowercased() {
        case "all": return Set(PIICategory.allCases)
        case "none", "off": return []
        default:
            var categories = Set<PIICategory>()
            for item in redact.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                guard let category = PIICategory(rawValue: item) else {
                    throw ValidationError(
                        "Unknown redaction category '\(item)'. Use: "
                            + PIICategory.allCases.map(\.rawValue).joined(separator: ", "))
                }
                categories.insert(category)
            }
            return categories
        }
    }

    /// Where to write the minutes for a meeting that started at `date`.
    func outputURL(startedAt date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let cleanTitle = (title ?? "Meeting").components(separatedBy: CharacterSet(charactersIn: "/:\\\n")).joined(
            separator: "-")
        let fileName = "\(formatter.string(from: date)) \(cleanTitle).md"

        guard let output else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Minutes", isDirectory: true)
                .appendingPathComponent(fileName)
        }
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        return url.pathExtension.lowercased() == "md" ? url : url.appendingPathComponent(fileName)
    }

    func title(startedAt date: Date) -> String {
        if let title, !title.isEmpty { return title }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return "Meeting, \(formatter.string(from: date))"
    }
}

/// Loads the vendored models, printing progress to stderr.
func loadModels() throws -> LoadedModels {
    Console.quietLibraries()
    let store = try ModelStore.locate()
    return try ModelLoader.load(from: store) { message in Console.note(Style.dim(message + "…")) }
}

/// Asks for a name for each speaker, showing something they said. Enter keeps the label.
func promptForNames(_ document: MinutesDocument) -> [SpeakerID: String] {
    let speakers = document.speakers
    guard !speakers.isEmpty, Terminal.isInteractive else { return [:] }
    print("\n" + Style.bold("Who was speaking?") + " Type a name and press Return, or just press Return to skip.")
    print(Style.dim("Giving two speakers the same name combines them."))
    var names: [SpeakerID: String] = [:]
    for speaker in speakers {
        let sample = document.turns.filter { $0.speaker == speaker }.max { $0.text.count < $1.text.count }?.text ?? ""
        let quote = sample.count > 90 ? String(sample.prefix(90)) + "…" : sample
        print("  " + Style.bold(Style.color(speaker.description, LiveView.color(for: speaker))) + Style.dim("  “\(quote)”"))
        print("  > ", terminator: "")
        fflush(stdout)
        if let name = readLine()?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            names[speaker] = name
        }
    }
    return names
}
