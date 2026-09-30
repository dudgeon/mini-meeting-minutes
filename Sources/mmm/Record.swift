import ArgumentParser
import Darwin
import Foundation
import MinutesCore
import Synchronization

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a meeting from the microphone and system audio (the default command), or transcribe a "
            + "recording you already have.")

    @Argument(
        help: ArgumentHelp(
            "A recording to transcribe instead, such as a voice memo. Most audio and video files work: m4a, mp3, "
                + "wav, mov and more. It's only read.",
            valueName: "recording"))
    var recording: String?

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
        if noMic && noSystem && recording == nil {
            throw ValidationError("Nothing to record: --no-mic and --no-system together.")
        }
        if let recording, !FileManager.default.fileExists(atPath: (recording as NSString).expandingTildeInPath) {
            throw ValidationError("There's no recording at \(recording).")
        }
    }

    func run() async throws {
        let redaction = try minutes.redactionCategories()
        var requested = Set(Channel.allCases)
        if noMic || (replaying && replayRoom == nil) { requested.remove(.room) }
        if noSystem || (replaying && replayRemote == nil) { requested.remove(.remote) }
        var next = Next.live
        if let recording { next = .recording(URL(fileURLWithPath: (recording as NSString).expandingTildeInPath)) }
        // The microphone and system audio permissions are checked, and explained, before the first
        // live meeting; not when starting with a recording, which needs neither.
        var channels: Set<Channel>?
        if case .live = next { channels = replaying ? requested : try Setup.prepare(requested) }
        let models = try loadModels()
        let keep = minutes.wordsToKeep()
        // One terminal for the whole run: between meetings the screen stays up.
        let terminal = Terminal.isInteractive ? Terminal() : nil
        var look = skin
        var saved: [LiveState.Saved] = []
        var notice: String?
        // The microphone: --mic-device, else the one chosen last time, else the Mac's default.
        let remembered = Settings.microphone
        if micDevice == nil, let remembered, !AudioDevices.inputs().contains(where: { $0.uid == remembered.uid }) {
            notice = "The microphone you chose, \(remembered.name), isn't connected, so the Mac's default is used "
                + "until it is. Press M to choose another."
        }
        let microphones = MicrophoneChoice(micDevice ?? remembered?.uid)
        do {
            meetings: while true {
                let meeting: Meeting
                switch next {
                case .quit:
                    break meetings
                case .live:
                    // Later meetings use whichever microphone is there by then.
                    let available =
                        channels ?? requested.filter { $0 != .room || replaying || !AudioDevices.inputs().isEmpty }
                    channels = nil
                    meeting = try await recordMeeting(
                        models: models, redaction: redaction, keep: keep, requested: requested, channels: available,
                        microphones: microphones, recording: nil, terminal: terminal, look: look, notice: notice)
                case .recording(let url):
                    let reader: AudioFileReader
                    do {
                        reader = try await AudioFileReader.open(url)
                    } catch {
                        let problem =
                            (error as? AudioFileError)?.localizedDescription
                            ?? "“\(url.lastPathComponent)” couldn't be opened: \(error.localizedDescription)"
                        // On screen, say so where the next recording would start; without, stop.
                        guard terminal != nil else { throw FriendlyError(problem) }
                        notice = problem
                        next = .live
                        continue
                    }
                    meeting = try await recordMeeting(
                        models: models, redaction: redaction, keep: keep, requested: [.room], channels: [.room],
                        microphones: microphones, recording: RecordingFile(url: url, reader: reader),
                        terminal: terminal, look: look, notice: nil)
                }
                notice = nil
                if let minutes = meeting.saved { saved.append(minutes) }
                look = meeting.look
                // Without a screen there's no choosing what's next: one meeting a run.
                next = terminal == nil ? .quit : meeting.next
            }
        } catch {
            terminal?.leaveFullScreen()
            throw error
        }
        terminal?.leaveFullScreen()
        if saved.isEmpty { Console.note("Nothing was recorded.") }
        for (index, minutes) in saved.enumerated() {
            // Only the last path saved is still on the clipboard.
            Setup.finished(
                URL(fileURLWithPath: minutes.path), turns: minutes.turns, speakers: minutes.speakers,
                copied: minutes.copied && index == saved.count - 1, offerToOpen: false)
        }
    }

    /// What comes after a meeting.
    enum Next: Sendable, Equatable {
        /// A live meeting, from the ready screen.
        case live
        /// Transcribing a recording someone already has.
        case recording(URL)
        case quit
    }

    /// How a meeting ended.
    struct Meeting {
        var saved: LiveState.Saved?
        var next = Next.quit
        var look: Look
    }

    /// A recording to transcribe, opened.
    struct RecordingFile {
        let url: URL
        let reader: AudioFileReader

        var name: String { url.lastPathComponent }
        /// The recording's own title (Voice Memos keeps the memo's name in it), else its file name.
        var title: String { reader.title ?? url.deletingPathExtension().lastPathComponent }
    }

    /// Records one meeting: waits for Space and the go-ahead that everyone agrees, records until
    /// Q, Ctrl-C, the window closing or the end of a replay, saves the minutes, then shows them
    /// until the next choice. With a `recording`, it transcribes that instead, just as it would a
    /// meeting but as fast as the Mac allows, once it's confirmed that everyone in it agreed.
    private func recordMeeting(
        models: LoadedModels, redaction: Set<PIICategory>, keep: [String], requested: Set<Channel>,
        channels: Set<Channel>, microphones: MicrophoneChoice, recording: RecordingFile?, terminal: Terminal?,
        look: Look, notice: String?
    ) async throws -> Meeting {
        // With no microphone yet, the room channel is set up anyway, and one connected later is used.
        let awaitingMicrophone = recording == nil && requested.contains(.room) && !channels.contains(.room)
        var settings = PipelineSettings()
        // A recording is read as fast as the Mac allows. Readings of unfinished sentences would
        // only slow that down, and each sentence's words are there moments later anyway.
        if recording != nil { settings.interimSeconds = 0 }
        let session = try await MeetingSession(
            models: models,
            configuration: MeetingSession.Configuration(
                channels: requested, echoCancellation: !noEchoCancel && recording == nil, redaction: redaction,
                keep: keep, pipeline: settings))

        let live = LiveState()
        let now = Date()
        // A recording keeps its own date and title; a live meeting's come from when it begins.
        let recordedAt = recording.map { $0.reader.date ?? now }
        let name = recording.map { minutes.title ?? $0.title }
        live.update {
            $0.title = name ?? minutes.title(startedAt: now)
            $0.outputPath = minutes.outputURL(startedAt: recordedAt ?? now, name: name).path
            $0.redaction = redaction
            $0.channels = channels
            $0.awaitingMicrophone = awaitingMicrophone
            $0.look = look
            $0.notice = notice
            $0.microphoneChoosable = recording == nil && !replaying && requested.contains(.room)
            $0.microphoneChoice = microphones.current
            if let recording {
                $0.recording = LiveState.Recording(name: recording.name, length: recording.reader.duration)
                $0.sources = [.room: recording.name]
                $0.askingConsent = terminal != nil
            }
        }
        let echo = await session.echoCancellationEnabled
        live.update { $0.echoCancellation = echo }
        Task { await session.warmUp() }

        // Recording begins when Space is pressed (at once when there's no screen to press it on).
        // Until then the meters move, so you can check what's heard, but no audio goes anywhere,
        // and the meeting's clock, file name and date all come from the moment it begins.
        let clock = RecordingClock()
        let begin: @Sendable () -> Void = {
            guard clock.start() else { return }
            let date = recordedAt ?? Date()
            let path = MinutesOptions.unused(minutes.outputURL(startedAt: date, name: name)).path
            live.update {
                $0.startedAt = date
                $0.title = name ?? minutes.title(startedAt: date)
                $0.outputPath = path
                $0.notice = nil
            }
        }
        if terminal == nil { begin() }

        // How the meeting ends: Q, Ctrl-C or the end of the audio stop it; once it's saved, the
        // choice of what's next. A meeting that ends before it begins says what follows it.
        let (stops, stop) = AsyncStream.makeStream(of: Void.self)
        let (choices, choose) = AsyncStream.makeStream(of: Next.self)
        let then = Handoff<Next>()
        // A recording chosen before recording starts replaces the meeting; once one is saved, it's
        // what comes next. Without a file, the Mac's Open window asks for one.
        let openRecording: @Sendable (URL?) -> Void = { url in
            @Sendable func open(_ url: URL) {
                let snapshot = live.snapshot
                if snapshot.saved != nil {
                    choose.yield(.recording(url))
                } else if !snapshot.started && !snapshot.stopping && snapshot.recording == nil {
                    then.put(.recording(url))
                    stop.yield()
                }
            }
            if let url {
                open(url)
                return
            }
            guard !live.snapshot.choosingRecording else { return }
            live.update { $0.choosingRecording = true }
            Task {
                let chosen = await Recordings.choose()
                live.update { $0.choosingRecording = false }
                if let chosen { open(chosen) }
            }
        }
        // Turning down a recording (not everyone agreed) goes back to the ready screen.
        let declined: @Sendable () -> Void = {
            guard live.snapshot.recording != nil else { return }
            then.put(.live)
            stop.yield()
        }

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
        let roomSamples = deliver(.room)
        let makeMicrophone: @Sendable () -> MicrophoneCapture = {
            var configuration = MicrophoneCapture.Configuration()
            configuration.inputDeviceUID = microphones.current
            return MicrophoneCapture(
                configuration: configuration,
                onEvent: { event in
                    switch event {
                    case .started(_, _, let device), .restarted(_, _, let device):
                        let name = device ?? "microphone"
                        live.update { state in
                            // Every microphone a meeting used goes in its minutes, in order.
                            if state.started, let used = state.sources[.room], !used.hasSuffix(name) {
                                state.sources[.room] = used + ", then " + name
                            } else if !state.started || state.sources[.room] == nil {
                                state.sources[.room] = name
                            }
                        }
                    case .restarting(let reason):
                        live.warn("Microphone restarting: \(reason)")
                    case .failed(let error):
                        live.warn("Microphone stopped: \(error)")
                    }
                },
                onSamples: roomSamples)
        }

        let microphone = MicrophoneSlot()
        var system: SystemAudioCapture?
        var replay: Task<Void, any Error>?
        var reading: Task<Void, Never>?
        if let recording {
            reading = read(recording, into: session, live: live, clock: clock, paused: paused, stop: stop)
        } else if replaying {
            replay = try await startReplay(live: live, clock: clock, paused: paused, feed: feedInput, stop: stop)
        }
        // Start the microphone first: opening a Bluetooth headset's mic flips it to another profile,
        // and a system tap built mid-switch can fail to deliver.
        if channels.contains(.room) && !replaying && recording == nil {
            let capture = makeMicrophone()
            do {
                try await capture.start()
                _ = microphone.put(capture)
            } catch MicrophoneCapture.CaptureError.permissionDenied {
                terminal?.leaveFullScreen()
                try Setup.blocked(
                    "Mini Meeting Minutes isn't allowed to use the microphone.",
                    fix: "In System Settings › Privacy & Security › Microphone, turn on \(Setup.hostApp).",
                    settings: Setup.microphoneSettings)
            } catch {
                throw RecordError.capture("microphone", error)
            }
        }
        if channels.contains(.remote) && !replaying && recording == nil {
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
                    notes: snapshot.notes, consentConfirmedAt: snapshot.consentedAt,
                    recording: snapshot.recording.map { MinutesDocument.Recording(name: $0.name, length: $0.length) })
                if (try? document.write(to: URL(fileURLWithPath: snapshot.outputPath))) != nil {
                    live.update { $0.savedAt = snapshot.elapsed }
                }
            }
        }
        let meetingIsLive = recording == nil
        let updates = Task {
            for await update in session.updates {
                live.apply(update)
                if case .turns = update { save.yield() }
                if meetingIsLive { Self.logLatency(of: update, now: clock.seconds(to: HostTime.now())) }
            }
        }

        // Show the live screen until q, Ctrl-C, or the end of a replay. Closing the window or
        // ending the process stops the recording the same way, but then no one is there to name
        // the speakers: the minutes are saved as they are. Once they're saved, the same keys quit.
        let hungUp = Latch()
        let (namesDone, finishNaming) = AsyncStream.makeStream(of: Void.self)
        let signals = [SIGINT, SIGHUP, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if number != SIGINT { hungUp.raise() }
                if live.snapshot.saved != nil {
                    choose.yield(.quit)
                } else if live.snapshot.naming?.final == true {
                    // While the speakers are being named: keep the names so far, and save.
                    live.update { $0.naming = nil }
                    finishNaming.yield()
                } else {
                    stop.yield()
                }
            }
            source.resume()
            return source
        }
        defer {
            for source in signals { source.cancel() }
            for number in [SIGINT, SIGHUP, SIGTERM] { signal(number, SIG_DFL) }
        }
        // Another microphone, chosen from the list: used from now on, in this meeting and the next,
        // and remembered for next time. The one in use stops first, since two can clash over a device.
        let chooseMicrophone: @Sendable (String?) -> Void = { uid in
            microphones.set(uid)
            let device = AudioDevices.inputs().first { $0.uid == uid }
            Settings.microphone = uid.flatMap { uid in device.map { (uid, $0.name) } }
            live.update {
                $0.microphoneChoice = uid
                $0.notice = nil
            }
            let snapshot = live.snapshot
            guard snapshot.microphoneChoosable, !snapshot.stopping, !snapshot.awaitingMicrophone else { return }
            Task {
                microphone.take()?.stop()
                let capture = makeMicrophone()
                do {
                    try await capture.start()
                    _ = microphone.put(capture)  // stopped at once if the meeting ended meanwhile
                } catch {
                    live.warn("Couldn't switch to that microphone (\(error)). Choose another with M or /mic.")
                }
            }
        }
        var screen = LiveScreen.start(
            terminal: terminal, live: live, clock: recording == nil ? clock : nil, naming: (namesDone, finishNaming),
            controls: LiveScreen.Controls(
                paused: paused, begin: begin, stop: stop, save: save, choose: choose, openRecording: openRecording,
                declined: declined, chooseMicrophone: chooseMicrophone, copyPath: Setup.copyToClipboard))
        if screen == nil {
            Console.note(
                recording.map {
                    "Transcribing “\($0.name)”. Make sure everyone in it knew it was being recorded, and agreed. "
                        + "Press Ctrl-C to stop."
                }
                    ?? "Recording. Make sure everyone taking part knows it's being recorded and transcribed, and "
                    + "agrees. Press Ctrl-C to stop.")
        }
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
        reading?.cancel()
        await reading?.value
        feedInput.finish()
        try await processing.value
        let turns = try await session.finish()
        _ = await updates.value
        save.finish()
        await saving.value

        guard let startedAt = live.snapshot.startedAt else {
            // Stopped before recording began: there's nothing to save. What follows is a recording
            // chosen instead, the ready screen after turning one down, or else leaving.
            await screen?.close()
            return Meeting(next: then.take() ?? .quit, look: live.snapshot.look)
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
        if let screen, !minutes.noNames, !speakers.isEmpty { await screen.askForNames(speakers) }

        let snapshot = live.snapshot
        let outputURL = URL(fileURLWithPath: snapshot.outputPath)
        var document = MinutesDocument(
            title: snapshot.title, startDate: startedAt,
            duration: recording == nil ? clock.seconds(to: HostTime.now()) ?? 0 : snapshot.elapsed,
            sources: snapshot.sources, redaction: redaction, echoCancellation: echo, turns: turns,
            names: snapshot.names, notes: snapshot.notes, consentConfirmedAt: snapshot.consentedAt, inProgress: false,
            recording: snapshot.recording.map { MinutesDocument.Recording(name: $0.name, length: $0.length) })
        if screen == nil && !unattended && !minutes.noNames { document.names = promptForNames(document) }
        try document.write(to: outputURL)
        // The full path goes on the clipboard, since what's next is often handing the minutes to
        // someone, or to an AI assistant. Only with a screen, and not for replays (a testing aid):
        // scripts' clipboards are left alone.
        let copied = terminal != nil && !replaying && Setup.copyToClipboard(outputURL.path)
        let saved = LiveState.Saved(
            path: outputURL.path, turns: turns.count, speakers: document.speakers.count, copied: copied)
        guard let screen else { return Meeting(saved: saved, look: live.snapshot.look) }

        // The final minutes stay on screen, with what to do next, unless the window has closed.
        live.update { $0.saved = saved }
        var next = Next.quit
        if !hungUp.isRaised {
            for await choice in choices {
                next = choice
                break
            }
        }
        await screen.close()
        return Meeting(saved: saved, next: next, look: live.snapshot.look)
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

    /// Reads a recording through the session as fast as the Mac allows, once it begins, keeping
    /// the screen's clock at the point reached, then stops, as the end of a meeting would. A
    /// problem partway through keeps what's been transcribed so far.
    private func read(
        _ recording: RecordingFile, into session: MeetingSession, live: LiveState, clock: RecordingClock,
        paused: PauseFlag, stop: AsyncStream<Void>.Continuation
    ) -> Task<Void, Never> {
        let reader = UncheckedBox(recording.reader)
        return Task {
            while !clock.started {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            // The speed shown is measured over the last few seconds of reading.
            var mark = (time: ContinuousClock.now, position: TimeInterval(0))
            var position: TimeInterval = 0
            do {
                while !Task.isCancelled, let chunk = try reader.value.next() {
                    if paused.isPaused {
                        while paused.isPaused && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
                        mark = (.now, position)
                    }
                    guard !Task.isCancelled else { break }
                    live.listen(.room, chunk.samples, level: chunk.rms)
                    try await session.ingest(.room, chunk)
                    position = chunk.endTime
                    let elapsed = mark.time.duration(to: .now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    let speed = seconds >= 1 ? (position - mark.position) / seconds : nil
                    if seconds >= 3 { mark = (.now, position) }
                    live.update {
                        $0.elapsed = position
                        if let speed { $0.recording?.speed = speed }
                    }
                }
            } catch {
                live.warn("Stopped partway through: \(error.localizedDescription)")
            }
            stop.yield()
        }
    }

    /// Plays the replay files through the live path in real time (times `replaySpeed`), then
    /// stops the recording.
    private func startReplay(
        live: LiveState, clock: RecordingClock, paused: PauseFlag,
        feed: AsyncStream<(Channel, AudioChunk)>.Continuation, stop: AsyncStream<Void>.Continuation
    ) async throws -> Task<Void, any Error> {
        var readers: [(Channel, AudioFileReader)] = []
        for (channel, path) in [(Channel.room, replayRoom), (.remote, replayRemote)] {
            guard let path else { continue }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            readers.append((channel, try await AudioFileReader.open(url, chunkSeconds: 0.1)))
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

    /// With MMM_DEBUG set, how far behind the meeting each update reaches the screen.
    private static func logLatency(of update: ChannelUpdate, now: TimeInterval?) {
        guard ProcessInfo.processInfo.environment["MMM_DEBUG"] != nil, let now else { return }
        let line: String
        switch update {
        case .pending(let channel, let text):
            line = String(format: "[%@] shown at %.2f: pending %d characters", channel.rawValue, now, text.count)
        case .turns(let turns):
            guard let last = turns.map(\.end).max() else { return }
            line = String(format: "shown at %.2f: %d turns, the last ending %.1f s earlier", now, turns.count, now - last)
        case .buffered:
            return
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
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

    /// Takes the capture out, to replace it with another microphone.
    func take() -> MicrophoneCapture? {
        state.withLock { state in
            defer { state.capture = nil }
            return state.capture
        }
    }
}

/// A value one task leaves for another to pick up.
final class Handoff<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)

    func put(_ new: Value) { value.withLock { $0 = new } }

    /// The value left, if any, which is then gone.
    func take() -> Value? {
        value.withLock { value in
            defer { value = nil }
            return value
        }
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

/// The full-screen meeting screen: drawn from before the recording starts until its minutes are
/// saved and it's time for the next, reacting to keys and clicks throughout.
struct LiveScreen {
    /// What keys and clicks can do to the meeting.
    struct Controls: Sendable {
        let paused: PauseFlag
        /// Starts recording.
        let begin: @Sendable () -> Void
        let stop: AsyncStream<Void>.Continuation
        /// Asks for the minutes file to be rewritten, after a note is added.
        let save: AsyncStream<Void>.Continuation
        /// On the saved screen: what's next.
        let choose: AsyncStream<Record.Next>.Continuation
        /// Transcribe a recording (one dropped on the window, or nil to choose one in the Open
        /// window), before recording starts or once the minutes are saved.
        let openRecording: @Sendable (URL?) -> Void
        /// Not everyone in the recording agreed: go back to the ready screen.
        let declined: @Sendable () -> Void
        /// Use this microphone (nil: the Mac's default) from now on.
        let chooseMicrophone: @Sendable (String?) -> Void
        /// Puts text on the clipboard, and says whether that worked.
        let copyPath: @Sendable (String) -> Bool
    }

    let terminal: Terminal
    let live: LiveState
    let keys: Task<Void, Never>
    let drawing: Task<Void, Never>
    let namesDone: AsyncStream<Void>

    /// Takes over the terminal (if it hasn't already), or returns nil when there is none. The
    /// meeting's clock drives the time shown; without one (a recording), whatever reads it does.
    static func start(
        terminal: Terminal?, live: LiveState, clock: RecordingClock?,
        naming: (done: AsyncStream<Void>, finish: AsyncStream<Void>.Continuation), controls: Controls
    ) -> LiveScreen? {
        guard let terminal else { return nil }
        terminal.enterFullScreen()
        let (namesDone, finishNaming) = naming
        let keys = Task {
            for await key in terminal.keys() {
                handle(key, live: live, controls: controls, finishNaming: finishNaming)
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
                    if !$0.stopping, let seconds = clock?.seconds(to: HostTime.now()) { $0.elapsed = seconds }
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

    /// Stops drawing and reading keys. The terminal stays full screen, for the next meeting.
    func close() async {
        drawing.cancel()
        _ = await drawing.value
        terminal.stopReadingKeys()
        keys.cancel()
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: Input

    static func handle(
        _ key: Key, live: LiveState, controls: Controls, finishNaming: AsyncStream<Void>.Continuation
    ) {
        let snapshot = live.snapshot
        if snapshot.naming != nil {
            if editNames(key, live: live) { finishNaming.yield() }
            return
        }
        if snapshot.microphones != nil {
            editMicrophones(key, live: live, controls: controls)
            return
        }
        if let saved = snapshot.saved {
            handleSaved(key, saved, snapshot: snapshot, live: live, controls: controls)
            return
        }
        if snapshot.askingConsent {
            handleConsent(key, snapshot: snapshot, live: live, controls: controls)
            return
        }
        if snapshot.help {
            live.update { $0.help = false }
            return
        }
        // F8 (the ⏯ key, with fn) does what Space does, even partway through a note.
        if case .function(8) = key {
            perform(.pause, snapshot: snapshot, live: live, controls: controls)
            return
        }
        // While a meeting runs, the prompt box takes what's typed: a note, or a command after a
        // slash. So no sentence typed into it can stop or rearrange the meeting. Scrolling and
        // clicks work as usual.
        if snapshot.started && !snapshot.stopping && !snapshot.finished && type(key, live: live, controls: controls) {
            return
        }
        // A file dropped on the window arrives as a paste of its path: before recording, that's a
        // recording to transcribe.
        if case .paste(let text) = key {
            if !snapshot.started && snapshot.recording == nil && !snapshot.stopping { dropped(text, live, controls) }
            return
        }
        // Before a meeting starts, and while it finishes, single keys do things.
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
            case "o": action = .openRecording
            case "m": action = .chooseMicrophone
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
        if let action { perform(action, snapshot: snapshot, live: live, controls: controls) }
    }

    /// Does what a key, a click or a slash command asks.
    private static func perform(
        _ action: ScreenAction, snapshot: LiveState.Snapshot, live: LiveState, controls: Controls
    ) {
        let busy = snapshot.stopping || snapshot.finished
        switch action {
        case .stop:
            if !busy { controls.stop.yield() }
        case .pause, .resume:
            if !snapshot.started {
                // Before recording, everyone taking part has to know and agree.
                if !busy { live.update { $0.askingConsent = true } }
            } else if !busy && (action == .pause || controls.paused.isPaused) {
                let nowPaused = controls.paused.toggle()
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
        case .openRecording:
            if !snapshot.started && snapshot.recording == nil && !busy { controls.openRecording(nil) }
        case .chooseMicrophone:
            if snapshot.microphoneChoosable && !busy {
                live.update { $0.microphones = .current(chosen: $0.microphoneChoice) }
            } else if snapshot.recording != nil {
                live.update { $0.notice = "Transcribing a recording uses no microphone." }
            }
        case .microphone, .consent, .decline, .newMeeting, .open, .reveal, .copyPath, .quit: break
        }
    }

    /// The list of microphones: ↑↓ or Tab move, Return (or its number, or a click) chooses one,
    /// Escape keeps the one in use.
    private static func editMicrophones(_ key: Key, live: LiveState, controls: Controls) {
        var chosen: LiveState.MicrophonePicker.Option?
        live.update { state in
            guard var picker = state.microphones else { return }
            switch key {
            case .up:
                picker.selected = max(0, picker.selected - 1)
            case .down, .tab:
                picker.selected = min(picker.options.count - 1, picker.selected + 1)
            case .enter:
                chosen = picker.options[picker.selected]
            case .char(let char):
                if let number = char.wholeNumberValue, picker.options.indices.contains(number - 1) {
                    chosen = picker.options[number - 1]
                }
            case .click(let x, let y):
                if case .microphone(let index)? = state.regions.last(where: { $0.contains(x, y) })?.action,
                    picker.options.indices.contains(index)
                {
                    chosen = picker.options[index]
                }
            case .escape:
                state.microphones = nil
                return
            default:
                break
            }
            state.microphones = chosen == nil ? picker : nil
        }
        if let chosen { controls.chooseMicrophone(chosen.uid) }
    }

    /// Text pasted before recording, or on the saved screen: a recording dropped on the window is
    /// transcribed; any other file gets a word on why not.
    private static func dropped(_ text: String, _ live: LiveState, _ controls: Controls) {
        if let url = Recordings.url(fromPasted: text) {
            controls.openRecording(url)
        } else if let file = Recordings.files(inPasted: text).first {
            live.update {
                $0.notice =
                    "“\(file.lastPathComponent)” isn't a recording. Drop a sound or video file, like a voice memo."
            }
        }
    }

    /// The question before recording: Y (or a click on yes) confirms and starts, N or Escape
    /// goes back.
    private static func handleConsent(_ key: Key, snapshot: LiveState.Snapshot, live: LiveState, controls: Controls) {
        var agreed: Bool?
        switch key {
        case .char(let char) where char.lowercased() == "y": agreed = true
        case .char(let char) where char.lowercased() == "n": agreed = false
        case .escape: agreed = false
        case .click(let x, let y):
            switch snapshot.regions.last(where: { $0.contains(x, y) })?.action {
            case .consent: agreed = true
            case .decline: agreed = false
            default: break
            }
        default: break
        }
        guard let agreed else { return }
        live.update {
            $0.askingConsent = false
            if agreed { $0.consentedAt = Date() }
        }
        if agreed { controls.begin() } else { controls.declined() }
    }

    /// The saved screen: Space for another meeting, O (or a dropped file) for a recording, Return
    /// opens the minutes, R shows them in Finder, C copies their path again, Q or Escape quits.
    private static func handleSaved(
        _ key: Key, _ saved: LiveState.Saved, snapshot: LiveState.Snapshot, live: LiveState, controls: Controls
    ) {
        var action: ScreenAction?
        switch key {
        case .char(let char):
            switch char.lowercased() {
            case " ": action = .newMeeting
            case "o": action = .openRecording
            case "r": action = .reveal
            case "c": action = .copyPath
            case "q": action = .quit
            case "k": action = .skin
            case "f": action = .follow
            default: break
            }
        case .enter: action = .open
        case .escape: action = .quit
        case .up: scroll(1, live)
        case .down: scroll(-1, live)
        case .pageUp: scroll(10, live)
        case .pageDown: scroll(-10, live)
        case .wheelUp: scroll(3, live)
        case .wheelDown: scroll(-3, live)
        case .click(let x, let y): action = snapshot.regions.last { $0.contains(x, y) }?.action
        case .paste(let text): dropped(text, live, controls)
        default: break
        }
        switch action {
        case .newMeeting: controls.choose.yield(.live)
        case .quit, .stop: controls.choose.yield(.quit)
        case .openRecording: controls.openRecording(nil)
        case .open: Setup.openMinutes(saved.path)
        case .reveal: Setup.showInFinder(saved.path)
        case .copyPath:
            if controls.copyPath(saved.path) {
                live.update {
                    $0.saved?.copied = true
                    $0.notice = "Copied the path of the minutes to the clipboard."
                }
            }
        case .skin: live.update { $0.look = $0.look.next }
        case .follow: live.update { $0.scroll = 0 }
        default: break
        }
    }

    private static func scroll(_ rows: Int, _ live: LiveState) {
        live.update { $0.scroll = max(0, min($0.maxScroll, $0.scroll + rows)) }
    }

    /// Types into the prompt box while a meeting runs: a note, added where typing began when
    /// Return is pressed, or a command after a slash, run by Return. Escape clears it. Space
    /// before any note pauses. Returns false for keys that aren't typing (scrolling, clicks).
    private static func type(_ key: Key, live: LiveState, controls: Controls) -> Bool {
        switch key {
        case .char, .paste, .backspace, .enter, .escape, .tab: break
        default: return false
        }
        // A note never starts with a space, so Space pauses and resumes whenever no note is under
        // way, as it always has. Within a note, it's just a space.
        if case .char(" ") = key, live.snapshot.draft?.text.isEmpty ?? true {
            perform(.pause, snapshot: live.snapshot, live: live, controls: controls)
            return true
        }
        var command: Command?
        var added = false
        live.update { state in
            var draft = state.draft ?? LiveState.NoteDraft()
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
                if let first = Command.matching(draft.text).first { draft.text = "/" + first.rawValue }
            case .escape:
                state.draft = nil
                return
            case .enter:
                if Command.isCommand(draft.text) {
                    // A command runs; a slash and a word that isn't one stays, to be fixed.
                    command = Command.chosen(draft.text)
                    if command != nil { state.draft = nil }
                    return
                }
                state.draft = draft
                added = state.addDraft()
                if added { state.scroll = 0 }
                return
            default:
                break
            }
            state.draft = draft.text.isEmpty ? nil : draft
        }
        if added { controls.save.yield() }
        if let command { perform(command.action, snapshot: live.snapshot, live: live, controls: controls) }
        return true
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
