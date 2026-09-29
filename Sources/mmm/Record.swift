import ArgumentParser
import Darwin
import Foundation
import MinutesCore
import Synchronization

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a meeting from the microphone and system audio (the default command).")

    @OptionGroup var minutes: MinutesOptions

    @Flag(help: "Don't capture the microphone (room audio).")
    var noMic = false

    @Flag(help: "Don't capture system audio (remote participants).")
    var noSystem = false

    @Flag(help: "Don't remove speaker playback from the microphone. Fine when you wear headphones.")
    var noEchoCancel = false

    @Option(help: "Core Audio UID of the input device to use instead of the system default.")
    var micDevice: String?

    // Testing aids: play files through the live path instead of capturing.
    @Option(help: .hidden) var replayRoom: String?
    @Option(help: .hidden) var replayRemote: String?
    @Option(help: .hidden) var replaySpeed: Double = 1

    var replaying: Bool { replayRoom != nil || replayRemote != nil }

    func validate() throws {
        if noMic && noSystem { throw ValidationError("Nothing to record: --no-mic and --no-system together.") }
    }

    func run() async throws {
        let redaction = try minutes.redactionCategories()
        let models = try loadModels()

        var channels = Set(Channel.allCases)
        if noMic || (replaying && replayRoom == nil) { channels.remove(.room) }
        if noSystem || (replaying && replayRemote == nil) { channels.remove(.remote) }
        let session = try await MeetingSession(
            models: models,
            configuration: MeetingSession.Configuration(
                channels: channels, echoCancellation: !noEchoCancel, redaction: redaction))

        let startDate = Date()
        let origin = HostTime.now()
        let outputURL = minutes.outputURL(startedAt: startDate)
        let live = LiveState()
        live.update {
            $0.outputPath = outputURL.path
            $0.redaction = !redaction.isEmpty
        }
        let echo = await session.echoCancellationEnabled
        live.update { $0.echoCancellation = echo }

        // Audio flows capture callback -> feed -> session, in capture order, on one task.
        let (feed, feedInput) = AsyncStream.makeStream(of: (Channel, AudioChunk).self)
        let paused = PauseFlag()
        func deliver(_ channel: Channel) -> @Sendable ([Float], UInt64) -> Void {
            { samples, hostTime in
                let chunk = AudioChunk(samples: samples, time: HostTime.seconds(from: origin, to: hostTime))
                live.update { $0.levels[channel] = chunk.rms }
                if !paused.isPaused { feedInput.yield((channel, chunk)) }
            }
        }

        let (stops, stop) = AsyncStream.makeStream(of: Void.self)
        var microphone: MicrophoneCapture?
        var system: SystemAudioCapture?
        var replay: Task<Void, any Error>?
        if replaying {
            replay = try startReplay(live: live, paused: paused, feed: feedInput, stop: stop)
        }
        // Start the microphone first: opening a Bluetooth headset's mic flips it to another profile,
        // and a system tap built mid-switch can fail to deliver.
        if channels.contains(.room) && !replaying {
            var configuration = MicrophoneCapture.Configuration()
            configuration.inputDeviceUID = micDevice
            let capture = MicrophoneCapture(
                configuration: configuration,
                onEvent: { event in
                    switch event {
                    case .started(_, _, let device), .restarted(_, _, let device):
                        live.update { $0.sources[.room] = device ?? "microphone" }
                    case .restarting(let reason):
                        live.warn("Microphone restarting: \(reason)")
                    case .failed(let error):
                        live.warn("Microphone stopped: \(error)")
                    }
                },
                onSamples: deliver(.room))
            do {
                try await capture.start()
                microphone = capture
            } catch {
                throw RecordError.capture("microphone", error)
            }
        }
        if channels.contains(.remote) && !replaying {
            let capture = SystemAudioCapture(
                onEvent: { event in
                    switch event {
                    case .started, .rebuilt:
                        live.update { $0.sources[.remote] = "system audio" }
                    case .permissionProbeFailed:
                        live.warn(Self.systemPermissionHelp)
                    case .digitalSilence(_, let playing) where !playing.isEmpty:
                        live.warn("System audio is silent while other apps are playing. " + Self.systemPermissionHelp)
                    case .failed(let error):
                        live.warn("System audio stopped: \(error)")
                    case .overflow(let dropped):
                        live.warn("Dropped \(dropped) frames of system audio (the Mac is overloaded).")
                    default:
                        break
                    }
                },
                onSamples: deliver(.remote))
            do {
                try await capture.start()
                system = capture
            } catch {
                microphone?.stop()
                throw RecordError.capture("system audio", error)
            }
        }

        let processing = Task {
            var failure: (any Error)?
            for await (channel, chunk) in feed where failure == nil {
                do { try await session.ingest(channel, chunk) } catch { failure = error }
            }
            if let failure { throw failure }
        }
        let updates = Task {
            for await update in session.updates {
                live.apply(update)
                // Keep the file current (one write per attributed window), so a crash loses little.
                if case .turns = update {
                    let snapshot = live.snapshot
                    try? MinutesDocument(
                        title: minutes.title(startedAt: startDate), startDate: startDate,
                        duration: snapshot.elapsed, sources: snapshot.sources, redaction: redaction,
                        echoCancellation: echo, turns: snapshot.turns
                    ).write(to: outputURL)
                }
            }
        }

        try await runScreen(live: live, paused: paused, origin: origin, stops: stops, stop: stop)

        // Stop capturing, let the pipeline drain, then relabel speakers across the whole meeting.
        live.update { $0.stopping = true }
        microphone?.stop()
        system?.stop()
        replay?.cancel()
        _ = await replay?.result
        feedInput.finish()
        try await processing.value
        let turns = try await session.finish()
        _ = await updates.value

        let snapshot = live.snapshot
        var document = MinutesDocument(
            title: minutes.title(startedAt: startDate), startDate: startDate,
            duration: HostTime.seconds(from: origin, to: HostTime.now()), sources: snapshot.sources,
            redaction: redaction, echoCancellation: echo, turns: turns, inProgress: false)
        if !minutes.noNames { document.names = promptForNames(document) }
        try document.write(to: outputURL)
        print("\n" + Style.green("Saved") + " \(LiveView.abbreviate(outputURL.path))  "
            + Style.dim("(\(turns.count) turns, \(document.speakers.count) speakers)"))
    }

    /// Shows the live screen until the user stops the recording (q or Ctrl-C).
    private func runScreen(
        live: LiveState, paused: PauseFlag, origin: UInt64, stops: AsyncStream<Void>,
        stop: AsyncStream<Void>.Continuation
    ) async throws {
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { stop.yield() }
        interrupt.resume()
        defer {
            interrupt.cancel()
            signal(SIGINT, SIG_DFL)
        }

        guard Terminal.isInteractive else {
            Console.note("Recording. Press Ctrl-C to stop.")
            for await _ in stops { break }
            return
        }

        let terminal = Terminal()
        terminal.enterFullScreen()
        defer { terminal.leaveFullScreen() }

        let keys = Task {
            for await key in terminal.keys() {
                switch key {
                case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                    stop.yield()
                case UInt8(ascii: "p"), UInt8(ascii: "P"), UInt8(ascii: " "):
                    let nowPaused = paused.toggle()
                    live.update { $0.paused = nowPaused }
                default:
                    break
                }
            }
        }
        let screen = Task {
            while !Task.isCancelled {
                live.update { $0.elapsed = HostTime.seconds(from: origin, to: HostTime.now()) }
                let size = terminal.size
                terminal.write(
                    "\u{1B}[H" + LiveView.render(live.snapshot, columns: size.columns, rows: size.rows) + "\u{1B}[J")
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        for await _ in stops { break }
        screen.cancel()
        terminal.stopReadingKeys()
        keys.cancel()
    }

    /// Plays the replay files through the live path in real time (times `replaySpeed`), then
    /// stops the recording.
    private func startReplay(
        live: LiveState, paused: PauseFlag, feed: AsyncStream<(Channel, AudioChunk)>.Continuation,
        stop: AsyncStream<Void>.Continuation
    ) throws -> Task<Void, any Error> {
        var readers: [(Channel, AudioFileReader)] = []
        for (channel, path) in [(Channel.room, replayRoom), (.remote, replayRemote)] {
            guard let path else { continue }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            readers.append((channel, try AudioFileReader(url: url, chunkSeconds: 0.1)))
            live.update { $0.sources[channel] = "replay of \(url.lastPathComponent)" }
        }
        let speed = max(replaySpeed, 0.1)
        let sources = UncheckedBox(readers)
        return Task {
            let readers = sources.value
            var next = try readers.map { try $0.1.next() }
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let candidates = next.indices.filter { next[$0] != nil }
                guard let index = candidates.min(by: { next[$0]!.time < next[$1]!.time }), let chunk = next[index]
                else { break }
                try await Task.sleep(until: start + .seconds(chunk.time / speed), clock: .continuous)
                live.update { $0.levels[readers[index].0] = chunk.rms }
                if !paused.isPaused { feed.yield((readers[index].0, chunk)) }
                next[index] = try readers[index].1.next()
            }
            stop.yield()
        }
    }

    static let systemPermissionHelp =
        "To capture remote participants, allow your terminal app under System Settings › Privacy & Security › "
        + "Screen & System Audio Recording › System Audio Recording Only, then restart the terminal."
}

enum RecordError: Error, CustomStringConvertible {
    case capture(String, any Error)

    var description: String {
        switch self {
        case .capture(let what, let error): "Couldn't start \(what) capture: \(error)"
        }
    }
}

/// Pausing drops captured audio before it reaches the pipeline.
final class PauseFlag: Sendable {
    private let paused = Atomic<Bool>(false)
    var isPaused: Bool { paused.load(ordering: .relaxed) }

    /// Flips the flag and returns the new state.
    func toggle() -> Bool {
        paused.logicalXor(true, ordering: .relaxed).newValue
    }
}

/// Carries a value that isn't Sendable into a task that becomes its only user.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
