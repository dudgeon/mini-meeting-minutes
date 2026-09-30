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

    @Option(help: "How the recording screen looks: sidebar or synthwave. Press K to switch while recording.")
    var skin: Look = .sidebar

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
        var requested = Set(Channel.allCases)
        if noMic || (replaying && replayRoom == nil) { requested.remove(.room) }
        if noSystem || (replaying && replayRemote == nil) { requested.remove(.remote) }
        let channels = replaying ? requested : try Setup.prepare(requested)
        // With no microphone yet, the room channel is set up anyway, and one connected later is used.
        let awaitingMicrophone = requested.contains(.room) && !channels.contains(.room)
        let models = try loadModels()
        let session = try await MeetingSession(
            models: models,
            configuration: MeetingSession.Configuration(
                channels: requested, echoCancellation: !noEchoCancel, redaction: redaction))

        let live = LiveState()
        let now = Date()
        live.update {
            $0.title = minutes.title(startedAt: now)
            $0.outputPath = minutes.outputURL(startedAt: now).path
            $0.redaction = !redaction.isEmpty
            $0.channels = channels
            $0.awaitingMicrophone = awaitingMicrophone
            $0.look = skin
        }
        let echo = await session.echoCancellationEnabled
        live.update { $0.echoCancellation = echo }

        // Recording begins when Space is pressed (at once when there's no screen to press it on).
        // Until then the meters move, so you can check what's heard, but no audio goes anywhere,
        // and the meeting's clock, file name and date all come from the moment it begins.
        let clock = RecordingClock()
        let begin: @Sendable () -> Void = {
            guard clock.start() else { return }
            let date = Date()
            live.update {
                $0.startedAt = date
                $0.title = minutes.title(startedAt: date)
                $0.outputPath = minutes.outputURL(startedAt: date).path
            }
        }
        if !Terminal.isInteractive { begin() }

        // Audio flows capture callback -> feed -> session, in capture order, on one task.
        let (feed, feedInput) = AsyncStream.makeStream(of: (Channel, AudioChunk).self)
        let paused = PauseFlag()
        func deliver(_ channel: Channel) -> @Sendable ([Float], UInt64) -> Void {
            { samples, hostTime in
                let time = clock.seconds(to: hostTime)
                let chunk = AudioChunk(samples: samples, time: time ?? 0)
                live.listen(channel, samples, level: chunk.rms)
                if let time, time >= 0, !paused.isPaused { feedInput.yield((channel, chunk)) }
            }
        }
        let micDevice = micDevice
        func makeMicrophone() -> MicrophoneCapture {
            var configuration = MicrophoneCapture.Configuration()
            configuration.inputDeviceUID = micDevice
            return MicrophoneCapture(
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
        }

        let (stops, stop) = AsyncStream.makeStream(of: Void.self)
        let microphone = MicrophoneSlot()
        var system: SystemAudioCapture?
        var replay: Task<Void, any Error>?
        if replaying {
            replay = try startReplay(live: live, clock: clock, paused: paused, feed: feedInput, stop: stop)
        }
        // Start the microphone first: opening a Bluetooth headset's mic flips it to another profile,
        // and a system tap built mid-switch can fail to deliver.
        if channels.contains(.room) && !replaying {
            let capture = makeMicrophone()
            do {
                try await capture.start()
                _ = microphone.put(capture)
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
                microphone.close()
                throw RecordError.capture("system audio", error)
            }
        }
        // Watch for a microphone to be connected, and use it from then on.
        let microphoneWatch: Task<Void, Never>? =
            awaitingMicrophone
            ? Task {
                let asking = "A microphone was connected. Allow \(Setup.hostApp) to use it in the dialog."
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, !AudioDevices.inputs().isEmpty else { continue }
                    if AudioPermissions.microphoneStatus == .notDetermined { live.warn(asking) }
                    let capture = makeMicrophone()
                    do {
                        try await capture.start()
                    } catch MicrophoneCapture.CaptureError.permissionDenied {
                        live.update {
                            $0.warnings.removeAll { $0 == asking }
                            $0.awaitingMicrophone = false
                        }
                        live.warn(
                            "The microphone isn't allowed: turn on \(Setup.hostApp) in System Settings › Privacy & "
                                + "Security › Microphone, then start again.")
                        return
                    } catch {
                        continue  // not ready yet; try again in a moment
                    }
                    guard microphone.put(capture) else { return }
                    live.update {
                        $0.warnings.removeAll { $0 == asking }
                        $0.channels.insert(.room)
                        $0.awaitingMicrophone = false
                    }
                    return
                }
            } : nil

        let processing = Task {
            var failure: (any Error)?
            for await (channel, chunk) in feed where failure == nil {
                do { try await session.ingest(channel, chunk) } catch { failure = error }
            }
            if let failure { throw failure }
        }
        // Keep the file current, so a crash loses little: it's rewritten after each attributed
        // window and each note. One task does the writing, so writes never overlap, and each one
        // has everything so far.
        let (saves, save) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let saving = Task {
            for await _ in saves {
                let snapshot = live.snapshot
                guard let startedAt = snapshot.startedAt else { continue }
                let document = MinutesDocument(
                    title: snapshot.title, startDate: startedAt, duration: snapshot.elapsed, sources: snapshot.sources,
                    redaction: redaction, echoCancellation: echo, turns: snapshot.turns, names: snapshot.names,
                    notes: snapshot.notes)
                if (try? document.write(to: URL(fileURLWithPath: snapshot.outputPath))) != nil {
                    live.update { $0.savedAt = snapshot.elapsed }
                }
            }
        }
        let updates = Task {
            for await update in session.updates {
                live.apply(update)
                if case .turns = update { save.yield() }
            }
        }

        // Show the live screen until q, Ctrl-C, or the end of a replay. Closing the window or
        // ending the process stops the recording the same way, but then no one is there to name
        // the speakers: the minutes are saved as they are.
        let hungUp = Latch()
        let signals = [SIGINT, SIGHUP, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if number != SIGINT { hungUp.raise() }
                stop.yield()
            }
            source.resume()
            return source
        }
        defer {
            for source in signals { source.cancel() }
            for number in [SIGINT, SIGHUP, SIGTERM] { signal(number, SIG_DFL) }
        }
        var screen = LiveScreen.start(
            live: live, paused: paused, clock: clock, begin: begin, stop: stop, save: save)
        if screen == nil { Console.note("Recording. Press Ctrl-C to stop.") }
        for await _ in stops { break }
        let unattended = hungUp.isRaised
        if unattended, let closing = screen {
            await closing.close()
            screen = nil
        }
        // A note still being typed (Ctrl-C, or the end of a replay) is kept, not lost.
        live.update { state in _ = state.addDraft() }

        // Stop capturing, let the pipeline drain, then relabel speakers across the whole meeting.
        // The screen stays up meanwhile and shows the final labels.
        live.update { $0.stopping = true }
        microphoneWatch?.cancel()
        microphone.close()
        system?.stop()
        replay?.cancel()
        _ = await replay?.result
        feedInput.finish()
        try await processing.value
        let turns = try await session.finish()
        _ = await updates.value
        save.finish()
        await saving.value

        guard let startedAt = live.snapshot.startedAt else {
            // Stopped before recording began: there's nothing to save.
            await screen?.close()
            Console.note("Nothing was recorded.")
            return
        }
        let names = Self.carryNames(from: live.snapshot, to: turns)
        live.update {
            $0.turns = turns
            $0.pending = [:]
            $0.names = names
            $0.finished = true
        }

        let speakers = MinutesDocument(
            title: "", startDate: startedAt, sources: [:], redaction: [], echoCancellation: false, turns: turns
        ).speakers
        if let screen {
            if !minutes.noNames && !speakers.isEmpty { await screen.askForNames(speakers) }
            // Leave the final transcript, with names, on screen for a moment.
            try? await Task.sleep(for: .seconds(2))
            await screen.close()
        }

        let snapshot = live.snapshot
        let outputURL = URL(fileURLWithPath: snapshot.outputPath)
        var document = MinutesDocument(
            title: snapshot.title, startDate: startedAt, duration: clock.seconds(to: HostTime.now()) ?? 0,
            sources: snapshot.sources, redaction: redaction, echoCancellation: echo, turns: turns,
            names: snapshot.names, notes: snapshot.notes, inProgress: false)
        if screen == nil && !unattended && !minutes.noNames { document.names = promptForNames(document) }
        try document.write(to: outputURL)
        // Replays are automated (tests, the README demo): don't wait for a key. Nor when the
        // window has gone.
        Setup.finished(
            outputURL, turns: turns.count, speakers: document.speakers.count, offerToOpen: !replaying && !unattended)
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
        live: LiveState, clock: RecordingClock, paused: PauseFlag,
        feed: AsyncStream<(Channel, AudioChunk)>.Continuation, stop: AsyncStream<Void>.Continuation
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
            // Like a live recording, a replay begins when recording does.
            while !clock.started { try await Task.sleep(for: .milliseconds(20)) }
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

/// When recording began, as a host time. Audio from before is heard (the meters move) but not
/// recorded, and the meeting's times count from here.
final class RecordingClock: Sendable {
    private let origin = Atomic<UInt64>(0)

    var started: Bool { origin.load(ordering: .acquiring) != 0 }

    /// Starts the clock now. Returns false if it had already started.
    func start() -> Bool {
        origin.compareExchange(expected: 0, desired: HostTime.now(), ordering: .acquiringAndReleasing).exchanged
    }

    /// Seconds from the start to `hostTime` (negative before it), or nil if recording hasn't begun.
    func seconds(to hostTime: UInt64) -> TimeInterval? {
        let start = origin.load(ordering: .acquiring)
        return start == 0 ? nil : HostTime.seconds(from: start, to: hostTime)
    }
}

/// Holds the microphone capture, which may start after the rest (when a microphone is connected
/// mid-meeting), so it's stopped with the rest. Once closed, a capture put in is stopped at once.
final class MicrophoneSlot: Sendable {
    private let state = Mutex<(capture: MicrophoneCapture?, closed: Bool)>((nil, false))

    func put(_ capture: MicrophoneCapture) -> Bool {
        let accepted = state.withLock { state in
            guard !state.closed else { return false }
            state.capture = capture
            return true
        }
        if !accepted { capture.stop() }
        return accepted
    }

    func close() {
        let capture = state.withLock { state in
            state.closed = true
            defer { state.capture = nil }
            return state.capture
        }
        capture?.stop()
    }
}

/// A flag that, once raised, stays up.
final class Latch: Sendable {
    private let raised = Atomic<Bool>(false)
    var isRaised: Bool { raised.load(ordering: .relaxed) }
    func raise() { raised.store(true, ordering: .relaxed) }
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

    /// Takes over the terminal, or returns nil when it isn't interactive. `begin` starts the
    /// recording; `save` asks for the minutes file to be rewritten, after a note is added.
    static func start(
        live: LiveState, paused: PauseFlag, clock: RecordingClock, begin: @escaping @Sendable () -> Void,
        stop: AsyncStream<Void>.Continuation, save: AsyncStream<Void>.Continuation
    ) -> LiveScreen? {
        guard Terminal.isInteractive else { return nil }
        let terminal = Terminal()
        terminal.enterFullScreen()
        let (namesDone, finishNaming) = AsyncStream.makeStream(of: Void.self)
        let keys = Task {
            for await key in terminal.keys() {
                handle(
                    key, live: live, paused: paused, begin: begin, stop: stop, save: save, finishNaming: finishNaming)
            }
        }
        let drawing = Task {
            let screen = Screen()
            let analyzers: [Channel: SpectrumAnalyzer] = [.room: SpectrumAnalyzer(), .remote: SpectrumAnalyzer()]
            let frames = ContinuousClock()
            let start = frames.now
            var previous = start
            while !Task.isCancelled {
                let now = frames.now
                let interval = Self.seconds(now - previous)
                previous = now
                live.update {
                    if !$0.stopping, let seconds = clock.seconds(to: HostTime.now()) { $0.elapsed = seconds }
                }
                let snapshot = live.snapshot
                let size = terminal.size
                let (canvas, maxScroll) = snapshot.look.render(
                    snapshot, analyzers: analyzers, width: size.columns, height: size.rows,
                    time: Self.seconds(now - start), frameInterval: interval)
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

    static func handle(
        _ key: Key, live: LiveState, paused: PauseFlag, begin: @Sendable () -> Void,
        stop: AsyncStream<Void>.Continuation, save: AsyncStream<Void>.Continuation,
        finishNaming: AsyncStream<Void>.Continuation
    ) {
        let snapshot = live.snapshot
        if snapshot.naming != nil {
            if editNames(key, live: live) { finishNaming.yield() }
            return
        }
        // While a note is being typed, keys type into it; scrolling and clicks work as usual.
        if snapshot.draft != nil, let added = editNote(key, live: live) {
            if added { save.yield() }
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
        case .enter: action = .note
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
            if !snapshot.started {
                begin()
            } else if !busy {
                let nowPaused = paused.toggle()
                live.update { $0.paused = nowPaused }
            }
        case .resume:
            if !snapshot.started {
                begin()
            } else if !busy && paused.isPaused {
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
        case .note:
            if !busy && snapshot.started { live.update { if $0.draft == nil { $0.draft = LiveState.NoteDraft() } } }
        case .visualizer: live.update { $0.visualizer = $0.visualizer.next }
        case .skin: live.update { $0.look = $0.look.next }
        case .help: live.update { if $0.draft == nil { $0.help = true } }
        case .follow: live.update { $0.scroll = 0 }
        }
    }

    private static func scroll(_ rows: Int, _ live: LiveState) {
        live.update { $0.scroll = max(0, min($0.maxScroll, $0.scroll + rows)) }
    }

    /// Types into the note being written: Return adds it, Escape drops it. Returns nil for keys
    /// that aren't for the note (scrolling, clicks), otherwise whether a note was added.
    private static func editNote(_ key: Key, live: LiveState) -> Bool? {
        var result: Bool? = false
        live.update { state in
            guard var draft = state.draft else {
                result = nil
                return
            }
            switch key {
            case .char(let char):
                draft.start = draft.start ?? state.elapsed
                if draft.text.count < 1000 { draft.text.append(char) }
            case .paste(let text):
                draft.start = draft.start ?? state.elapsed
                // A note is one paragraph: line breaks in a paste become spaces.
                draft.text = String((draft.text + String(text.map { $0.isNewline ? " " : $0 })).prefix(1000))
            case .backspace:
                if !draft.text.isEmpty { draft.text.removeLast() }
            case .tab:
                break
            case .enter:
                state.draft = draft
                result = state.addDraft()
                if result == true { state.scroll = 0 }
                return
            case .escape:
                state.draft = nil
                return
            default:
                result = nil
                return
            }
            state.draft = draft
        }
        return result
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
            case .paste(let text):
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                state.names[speaker] = String(((state.names[speaker] ?? "") + line).prefix(40))
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
