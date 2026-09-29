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

    @Option(help: "How the recording screen looks: classic or synthwave. Press K to switch while recording.")
    var skin: SkinName = .classic

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
        var channels = Set(Channel.allCases)
        if noMic || (replaying && replayRoom == nil) { channels.remove(.room) }
        if noSystem || (replaying && replayRemote == nil) { channels.remove(.remote) }
        if !replaying { channels = try Setup.prepare(channels) }
        let models = try loadModels()
        let session = try await MeetingSession(
            models: models,
            configuration: MeetingSession.Configuration(
                channels: channels, echoCancellation: !noEchoCancel, redaction: redaction))

        let startDate = Date()
        let origin = HostTime.now()
        let outputURL = minutes.outputURL(startedAt: startDate)
        let live = LiveState()
        live.update {
            $0.title = minutes.title(startedAt: startDate)
            $0.outputPath = outputURL.path
            $0.redaction = !redaction.isEmpty
            $0.channels = channels
            $0.skin = Skin.all.firstIndex { $0.name == skin.rawValue } ?? 0
        }
        let echo = await session.echoCancellationEnabled
        live.update { $0.echoCancellation = echo }

        // Audio flows capture callback -> feed -> session, in capture order, on one task.
        let (feed, feedInput) = AsyncStream.makeStream(of: (Channel, AudioChunk).self)
        let paused = PauseFlag()
        func deliver(_ channel: Channel) -> @Sendable ([Float], UInt64) -> Void {
            { samples, hostTime in
                let chunk = AudioChunk(samples: samples, time: HostTime.seconds(from: origin, to: hostTime))
                live.listen(channel, samples, level: chunk.rms)
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
            } catch MicrophoneCapture.CaptureError.permissionDenied {
                try Setup.blocked(
                    "Mini Meeting Minutes isn't allowed to use the microphone.",
                    fix: "In System Settings › Privacy & Security › Microphone, turn on \(Setup.hostApp).",
                    settings: Setup.microphoneSettings)
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

        // Show the live screen until q, Ctrl-C, or the end of a replay.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { stop.yield() }
        interrupt.resume()
        defer {
            interrupt.cancel()
            signal(SIGINT, SIG_DFL)
        }
        let screen = LiveScreen.start(live: live, paused: paused, origin: origin, stop: stop)
        if screen == nil { Console.note("Recording. Press Ctrl-C to stop.") }
        for await _ in stops { break }

        // Stop capturing, let the pipeline drain, then relabel speakers across the whole meeting.
        // The screen stays up meanwhile and shows the final labels.
        live.update { $0.stopping = true }
        microphone?.stop()
        system?.stop()
        replay?.cancel()
        _ = await replay?.result
        feedInput.finish()
        try await processing.value
        let turns = try await session.finish()
        _ = await updates.value
        let names = Self.carryNames(from: live.snapshot, to: turns)
        live.update {
            $0.turns = turns
            $0.pending = [:]
            $0.names = names
            $0.finished = true
        }

        let speakers = MinutesDocument(
            title: "", startDate: startDate, sources: [:], redaction: [], echoCancellation: false, turns: turns
        ).speakers
        if let screen {
            if !minutes.noNames && !speakers.isEmpty { await screen.askForNames(speakers) }
            // Leave the final transcript, with names, on screen for a moment.
            try? await Task.sleep(for: .seconds(2))
            await screen.close()
        }

        let snapshot = live.snapshot
        var document = MinutesDocument(
            title: minutes.title(startedAt: startDate), startDate: startDate,
            duration: HostTime.seconds(from: origin, to: HostTime.now()), sources: snapshot.sources,
            redaction: redaction, echoCancellation: echo, turns: turns, names: snapshot.names, inProgress: false)
        if screen == nil && !minutes.noNames { document.names = promptForNames(document) }
        try document.write(to: outputURL)
        // Replays are automated (tests, the README demo): don't wait for a key.
        Setup.finished(outputURL, turns: turns.count, speakers: document.speakers.count, offerToOpen: !replaying)
    }

    /// Names given during the meeting belong to live labels, which the final relabeling can
    /// renumber. Each name moves to the final label that most of that speaker's speech ended up with.
    static func carryNames(from live: LiveState.Snapshot, to turns: [Turn]) -> [SpeakerID: String] {
        let finalLabel = Dictionary(turns.map { ($0.origin, $0.speaker) }, uniquingKeysWith: { first, _ in first })
        var names: [SpeakerID: String] = [:]
        for (speaker, name) in live.names where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            var votes: [SpeakerID: Double] = [:]
            for turn in live.turns where turn.speaker == speaker {
                if let label = finalLabel[turn.origin] { votes[label, default: 0] += max(turn.end - turn.start, 0.1) }
            }
            if let label = votes.max(by: { $0.value < $1.value })?.key, names[label] == nil { names[label] = name }
        }
        return names
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
                live.listen(readers[index].0, chunk.samples, level: chunk.rms)
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

/// The full-screen recording screen: drawn from the start of the recording until the minutes
/// are final, reacting to keys and clicks throughout.
struct LiveScreen {
    let terminal: Terminal
    let live: LiveState
    let keys: Task<Void, Never>
    let drawing: Task<Void, Never>
    let namesDone: AsyncStream<Void>

    /// Takes over the terminal, or returns nil when it isn't interactive.
    static func start(
        live: LiveState, paused: PauseFlag, origin: UInt64, stop: AsyncStream<Void>.Continuation
    ) -> LiveScreen? {
        guard Terminal.isInteractive else { return nil }
        let terminal = Terminal()
        terminal.enterFullScreen()
        let (namesDone, finishNaming) = AsyncStream.makeStream(of: Void.self)
        let keys = Task {
            for await key in terminal.keys() {
                handle(key, live: live, paused: paused, stop: stop, finishNaming: finishNaming)
            }
        }
        let drawing = Task {
            let screen = Screen()
            let analyzers: [Channel: SpectrumAnalyzer] = [.room: SpectrumAnalyzer(), .remote: SpectrumAnalyzer()]
            let clock = ContinuousClock()
            let start = clock.now
            var previous = start
            while !Task.isCancelled {
                let now = clock.now
                let interval = Self.seconds(now - previous)
                previous = now
                live.update { if !$0.stopping { $0.elapsed = HostTime.seconds(from: origin, to: HostTime.now()) } }
                let snapshot = live.snapshot
                let size = terminal.size
                let (canvas, maxScroll) = RetroView.render(
                    snapshot, skin: Skin.all[snapshot.skin % Skin.all.count], analyzers: analyzers,
                    width: size.columns, height: size.rows, time: Self.seconds(now - start), frameInterval: interval)
                live.update {
                    $0.regions = canvas.regions
                    $0.maxScroll = maxScroll
                    $0.scroll = min($0.scroll, maxScroll)
                }
                terminal.write(screen.frame(canvas))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return LiveScreen(terminal: terminal, live: live, keys: keys, drawing: drawing, namesDone: namesDone)
    }

    /// Shows the naming dialog for the final speakers and waits until it is closed.
    func askForNames(_ speakers: [SpeakerID]) async {
        live.update { $0.naming = LiveState.Naming(speakers: speakers, final: true) }
        for await _ in namesDone { break }
    }

    /// Stops drawing and gives the terminal back.
    func close() async {
        drawing.cancel()
        _ = await drawing.value
        terminal.stopReadingKeys()
        keys.cancel()
        terminal.leaveFullScreen()
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: Input

    private static func handle(
        _ key: Key, live: LiveState, paused: PauseFlag, stop: AsyncStream<Void>.Continuation,
        finishNaming: AsyncStream<Void>.Continuation
    ) {
        let snapshot = live.snapshot
        if snapshot.naming != nil {
            if editNames(key, live: live) { finishNaming.yield() }
            return
        }
        if snapshot.help {
            live.update { $0.help = false }
            return
        }
        var action: ScreenAction?
        switch key {
        case .char(let char):
            switch char.lowercased() {
            case "q": action = .stop
            case " ", "p": action = .pause
            case "n": action = .name
            case "v": action = .visualizer
            case "k": action = .skin
            case "?", "h": action = .help
            case "f": action = .follow
            default: break
            }
        case .up: scroll(1, live)
        case .down: scroll(-1, live)
        case .pageUp: scroll(10, live)
        case .pageDown: scroll(-10, live)
        case .home: scroll(Int.max / 2, live)
        case .end: action = .follow
        case .wheelUp: scroll(3, live)
        case .wheelDown: scroll(-3, live)
        case .click(let x, let y): action = snapshot.regions.last { $0.contains(x, y) }?.action
        default: break
        }
        guard let action else { return }
        let busy = snapshot.stopping || snapshot.finished
        switch action {
        case .stop:
            if !busy { stop.yield() }
        case .pause:
            if !busy {
                let nowPaused = paused.toggle()
                live.update { $0.paused = nowPaused }
            }
        case .resume:
            if !busy && paused.isPaused {
                let nowPaused = paused.toggle()
                live.update { $0.paused = nowPaused }
            }
        case .name:
            live.update { state in
                var speakers: [SpeakerID] = []
                for turn in state.turns.sorted(by: { $0.start < $1.start }) where !speakers.contains(turn.speaker) {
                    speakers.append(turn.speaker)
                }
                if !speakers.isEmpty && !state.finished { state.naming = LiveState.Naming(speakers: speakers) }
            }
        case .visualizer: live.update { $0.visualizer = $0.visualizer.next }
        case .skin: live.update { $0.skin = ($0.skin + 1) % Skin.all.count }
        case .help: live.update { $0.help = true }
        case .follow: live.update { $0.scroll = 0 }
        }
    }

    private static func scroll(_ rows: Int, _ live: LiveState) {
        live.update { $0.scroll = max(0, min($0.maxScroll, $0.scroll + rows)) }
    }

    /// Edits names in the naming dialog. Returns true when the end-of-meeting dialog closes.
    private static func editNames(_ key: Key, live: LiveState) -> Bool {
        var finished = false
        live.update { state in
            guard var naming = state.naming else { return }
            let speaker = naming.speakers[naming.selected]
            var close = false
            switch key {
            case .char(let char):
                if (state.names[speaker] ?? "").count < 40 { state.names[speaker, default: ""].append(char) }
            case .backspace:
                if var name = state.names[speaker], !name.isEmpty {
                    name.removeLast()
                    state.names[speaker] = name
                }
            case .enter:
                if naming.selected + 1 < naming.speakers.count { naming.selected += 1 } else { close = true }
            case .down, .tab: naming.selected = min(naming.speakers.count - 1, naming.selected + 1)
            case .up: naming.selected = max(0, naming.selected - 1)
            case .escape: close = true
            default: break
            }
            if close {
                state.naming = nil
                finished = naming.final
            } else {
                state.naming = naming
            }
        }
        return finished
    }
}
