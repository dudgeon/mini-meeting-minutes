import ArgumentParser
import Foundation
import MinutesCore

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe existing audio files through the same pipeline, faster than real time.",
        discussion: """
            Pass the room side, the remote side, or both (e.g. separate microphone and call tracks). \
            The files are only read.
            """)

    @Option(help: "Audio file of the room (microphone) side.")
    var room: String?

    @Option(help: "Audio file of the remote (call / system audio) side.")
    var remote: String?

    @OptionGroup var minutes: MinutesOptions

    @Flag(help: "Don't use the remote track to cancel its echo in the room track.")
    var noEchoCancel = false

    @Flag(help: "Print the minutes to standard output instead of writing a file.")
    var stdout = false

    func validate() throws {
        if room == nil && remote == nil { throw ValidationError("Pass --room, --remote, or both.") }
    }

    func run() async throws {
        let redaction = try minutes.redactionCategories()
        var readers: [(Channel, AudioFileReader)] = []
        var sources: [Channel: String] = [:]
        for (channel, path) in [(Channel.room, room), (.remote, remote)] {
            guard let path else { continue }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            readers.append((channel, try await AudioFileReader.open(url)))
            sources[channel] = url.lastPathComponent
        }

        let models = try loadModels()
        let session = try await MeetingSession(
            models: models,
            configuration: MeetingSession.Configuration(
                channels: Set(readers.map(\.0)), echoCancellation: !noEchoCancel, redaction: redaction,
                keep: minutes.wordsToKeep()))
        let echo = await session.echoCancellationEnabled
        let progress = Task {
            for await update in session.updates {
                guard case .turns(let turns) = update else { continue }
                for turn in turns {
                    Console.note(
                        "\(Style.dim(MinutesDocument.timestamp(turn.start))) \(Style.bold(turn.speaker.description)): \(turn.text)")
                }
            }
        }

        // Feed both files in time order, as live capture would.
        var next = try readers.map { try $0.1.next() }
        while true {
            let candidates = next.indices.filter { next[$0] != nil }
            guard let index = candidates.min(by: { next[$0]!.time < next[$1]!.time }), let chunk = next[index] else {
                break
            }
            try await session.ingest(readers[index].0, chunk)
            next[index] = try readers[index].1.next()
        }
        let turns = try await session.finish()
        await progress.value

        let startDate = Date()
        var document = MinutesDocument(
            title: minutes.title ?? sources.values.sorted().joined(separator: " + "), startDate: startDate,
            duration: readers.map(\.1.duration).max() ?? 0, sources: sources, redaction: redaction,
            echoCancellation: echo, turns: turns, inProgress: false)
        if stdout {
            print(document.markdown(), terminator: "")
            return
        }
        if !minutes.noNames { document.names = promptForNames(document) }
        let url = MinutesOptions.unused(minutes.outputURL(startedAt: startDate))
        try document.write(to: url)
        Setup.finished(url, turns: turns.count, speakers: document.speakers.count)
    }
}
