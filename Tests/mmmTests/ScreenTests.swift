import Foundation
import MinutesCore
import Synchronization
import Testing

@testable import mmm

@Suite struct KeyParserTests {
    func keys(_ text: String) -> [Key] {
        var parser = KeyParser()
        return text.utf8.flatMap { parser.feed($0) }
    }

    @Test func arrowsAndPaging() {
        #expect(keys("\u{1B}[A\u{1B}[B\u{1B}[5~\u{1B}[6~\u{1B}[H\u{1B}[F") == [.up, .down, .pageUp, .pageDown, .home, .end])
    }

    @Test func mouseClicksAndWheel() {
        // Presses count, releases don't; coordinates become zero-based.
        #expect(keys("\u{1B}[<0;10;5M\u{1B}[<0;10;5m\u{1B}[<64;1;1M\u{1B}[<65;1;1M") == [
            .click(x: 9, y: 4), .wheelUp, .wheelDown,
        ])
    }

    @Test func typingIncludingAccents() {
        #expect(keys("Zoë\r\u{7F}\t") == [.char("Z"), .char("o"), .char("ë"), .enter, .backspace, .tab])
    }

    @Test func pastesArriveWhole() {
        // A paste can hold Return and letters that are shortcuts; none of them may act as keys.
        #expect(keys("\u{1B}[200~quick\nnote\u{1B}[201~x") == [.paste("quick\nnote"), .char("x")])
    }

    @Test func functionKeys() {
        // F8 (the ⏯ key with fn) as Terminal and iTerm send it, with and without modifiers; F1.
        #expect(keys("\u{1B}[19~") == [.function(8)])
        #expect(keys("\u{1B}[19;2~") == [.function(8)])
        #expect(keys("\u{1B}OP") == [.function(1)])
        #expect(keys("\u{1B}[5~\u{1B}[A") == [.pageUp, .up])  // other sequences are unchanged
    }

    @Test func escapeOnItsOwn() {
        var parser = KeyParser()
        #expect(parser.feed(0x1B).isEmpty)
        #expect(parser.idle() == [.escape])
        #expect(parser.idle().isEmpty)
    }
}

@Suite struct ScreenTests {
    @Test func redrawsOnlyWhatChanged() {
        let screen = Screen()
        var canvas = Canvas(width: 12, height: 3, background: RGB(0x000000))
        let first = screen.frame(canvas)
        #expect(first.contains("\u{1B}[2J"))
        canvas.put(3, 1, "X", fg: RGB(0xFFFFFF))
        let second = screen.frame(canvas)
        #expect(!second.contains("\u{1B}[2J"))
        #expect(second.contains("\u{1B}[2;4H"))
        #expect(second.filter { $0 == "X" }.count == 1)
        #expect(second.hasPrefix("\u{1B}[?2026h") && second.hasSuffix("\u{1B}[?2026l"))
    }
}

@Suite struct LookTests {
    static func snapshot() -> LiveState.Snapshot {
        var state = LiveState.Snapshot()
        state.channels = [.room, .remote]
        state.elapsed = 75
        let room = SpeakerID(channel: .room, number: 1)
        let remote = SpeakerID(channel: .remote, number: 1)
        state.turns = [
            Turn(channel: .room, speaker: room, origin: SegmentKey(channel: .room, window: 0, segment: 0),
                 start: 0, end: 6, text: "Good morning everyone. Let's get started with the planning review."),
            Turn(channel: .remote, speaker: remote, origin: SegmentKey(channel: .remote, window: 0, segment: 0),
                 start: 7, end: 15, text: "Thanks. I spoke with [NAME] about the budget."),
        ]
        state.pending = [.room: "That is concerning, can you send me"]
        state.recent = [.room: (0..<2048).map { sin(Float($0) / 9) * 0.2 }]
        state.outputPath = "/tmp/minutes.md"
        state.title = "Planning review"
        state.startedAt = Date(timeIntervalSince1970: 0)
        return state
    }

    static func render(_ state: LiveState.Snapshot, _ look: Look, _ width: Int, _ height: Int) -> Canvas {
        look.render(
            state, analyzers: [.room: SpectrumAnalyzer(), .remote: SpectrumAnalyzer()], width: width, height: height,
            time: 1, frameInterval: 0.05
        ).canvas
    }

    static func text(_ canvas: Canvas) -> String {
        String(canvas.cells.map(\.char))
    }

    @Test(arguments: Look.allCases, [(120, 42), (100, 30), (84, 24), (60, 16), (50, 12), (30, 8)])
    func rendersEverySize(look: Look, size: (Int, Int)) {
        var state = Self.snapshot()
        for visualizer in VisualizerMode.allCases {
            state.visualizer = visualizer
            let text = Self.text(Self.render(state, look, size.0, size.1))
            if size.0 >= 50 && size.1 >= 12 {
                // The newest words are always on screen; older ones scroll away in small windows.
                #expect(text.contains("That is concerning"))
                #expect(text.contains(look == .sidebar ? "identifying speaker" : "LIVE"))
                if size.1 >= 24 { #expect(text.contains("Good morning everyone.")) }
            } else {
                #expect(text.lowercased().contains("make this window bigger"))
            }
        }
    }

    @Test func sidebarAppearsWhenThereIsRoom() {
        #expect(Self.text(Self.render(Self.snapshot(), .sidebar, 120, 42)).contains("SPEAKERS"))
        #expect(!Self.text(Self.render(Self.snapshot(), .sidebar, 80, 42)).contains("SPEAKERS"))
    }

    @Test func synthwavePaintsItsPictureAboveTheTranscript() {
        let canvas = Self.render(Self.snapshot(), .synthwave, 120, 42)
        #expect(Self.text(canvas).contains("MINI MEETING MINUTES"))
        #expect((0..<120).contains { canvas[$0, 10].char == "▀" })
        // A short window drops the picture but keeps the words.
        let short = Self.render(Self.snapshot(), .synthwave, 120, 20)
        #expect(!short.cells.contains { $0.char == "▀" })
        #expect(Self.text(short).contains("Good morning everyone."))
    }

    @Test(arguments: Look.allCases)
    func namingAndClicks(look: Look) {
        var state = Self.snapshot()
        let speaker = SpeakerID(channel: .room, number: 1)
        state.naming = LiveState.Naming(speakers: [speaker])
        state.names = [speaker: "Priya"]
        let named = Self.text(Self.render(state, look, 120, 42))
        #expect(named.lowercased().contains("who was speaking?"))
        #expect(named.contains("Priya") || named.contains("PRIYA"))
        let canvas = Self.render(Self.snapshot(), look, 120, 42)
        let actions = Set(canvas.regions.map { "\($0.action)" })
        #expect(actions.isSuperset(of: ["stop", "pause", "name", "note", "visualizer", "skin", "help"]))
    }

    @Test(arguments: Look.allCases)
    func notesInTheTimeline(look: Look) {
        var state = Self.snapshot()
        state.notes = [Note(time: 6.5, text: "Ask for the quarterly numbers")]
        let text = Self.text(Self.render(state, look, 120, 42))
        #expect(text.contains("Ask for the quarterly numbers"))
        // Between the two turns: after the first speaker's words, before the second's.
        let note = text.range(of: "Ask for the quarterly numbers")!.lowerBound
        #expect(text.range(of: "planning review.")!.lowerBound < note)
        #expect(note < text.range(of: "about the budget.")!.lowerBound)
        // A note being typed shows where it's typed.
        state.draft = LiveState.NoteDraft(text: "Budget owner is", start: 40)
        #expect(Self.text(Self.render(state, look, 120, 42)).contains("Budget owner is"))
    }

    @Test(arguments: Look.allCases)
    func readyBeforeRecordingAndWaitingForAMicrophone(look: Look) {
        var state = LiveState.Snapshot()
        state.channels = [.remote]
        state.awaitingMicrophone = true
        state.outputPath = "/tmp/minutes.md"
        let text = Self.text(Self.render(state, look, 120, 42))
        #expect(text.lowercased().contains("press space to start recording"))
        #expect(text.contains(look == .sidebar ? "none connected" : "NONE YET"))
        #expect(!text.lowercased().contains("minutes.md"))  // the file is named when recording begins
        let actions = Set(Self.render(state, look, 120, 42).regions.map { "\($0.action)" })
        #expect(actions.contains("pause") && actions.contains("stop") && !actions.contains("note"))
    }

    @Test(arguments: Look.allCases)
    func askingForConsentThenSaved(look: Look) {
        var state = LiveState.Snapshot()
        state.channels = [.room, .remote]
        state.askingConsent = true
        let asking = Self.render(state, look, 120, 42)
        #expect(Self.text(asking).lowercased().contains("before you record"))
        #expect(Self.text(asking).contains("California"))
        #expect(Set(asking.regions.map { "\($0.action)" }).isSuperset(of: ["consent", "decline"]))

        var saved = Self.snapshot()
        saved.finished = true
        saved.saved = LiveState.Saved(path: "/Users/someone/Documents/Minutes/x.md", turns: 2, speakers: 2)
        let done = Self.render(saved, look, 120, 42)
        #expect(Self.text(done).lowercased().contains("saved"))
        #expect(Self.text(done).contains("Good morning everyone."))
        #expect(Set(done.regions.map { "\($0.action)" }).isSuperset(of: ["newMeeting", "open", "reveal", "quit"]))
    }

    @Test(arguments: Look.allCases, [(120, 42), (100, 30), (84, 24), (60, 16), (50, 12)])
    func transcribingARecording(look: Look, size: (Int, Int)) {
        var state = Self.snapshot()
        state.channels = [.room]
        state.recording = LiveState.Recording(name: "Team sync.m4a", length: 300, speed: 42)
        state.sources = [.room: "Team sync.m4a"]
        let text = Self.text(Self.render(state, look, size.0, size.1))
        #expect(text.contains("That is concerning"))
        if look == .sidebar {
            #expect(text.contains("Transcribing"))
            if size.0 >= 84 && size.1 >= 20 { #expect(text.contains("25%") && text.contains("file")) }
            if size.0 >= 100 { #expect(text.contains("42× speed")) }
        } else {
            #expect(text.contains("TRANSCRIBING") || size.0 < 60)
            if size.0 >= 100 { #expect(text.contains("00:05:00") && text.contains("FILE")) }
        }
        #expect(!text.contains("REC ") && !text.contains("● Recording"))

        // Asked first, in words for a recording made before.
        var asking = state
        asking.startedAt = nil
        asking.turns = []
        asking.pending = [:]
        asking.askingConsent = true
        let question = Self.render(asking, look, size.0, size.1)
        if size.1 >= 16 { #expect(Self.text(question).lowercased().contains("before you transcribe")) }
        if size.0 >= 84 {  // narrower, the answers are keys only
            #expect(Set(question.regions.map { "\($0.action)" }).isSuperset(of: ["consent", "decline"]))
        }
    }

    @Test(arguments: Look.allCases)
    func aRecordingCanBeOpenedBeforeAndAfter(look: Look) {
        var ready = LiveState.Snapshot()
        ready.channels = [.room, .remote]
        let before = Self.render(ready, look, 120, 42)
        #expect(Set(before.regions.map { "\($0.action)" }).contains("openRecording"))
        var saved = Self.snapshot()
        saved.finished = true
        saved.saved = LiveState.Saved(path: "/tmp/x.md", turns: 2, speakers: 2)
        #expect(Set(Self.render(saved, look, 120, 42).regions.map { "\($0.action)" }).contains("openRecording"))
        // Not while recording.
        let recording = Self.render(Self.snapshot(), look, 120, 42)
        #expect(!Set(recording.regions.map { "\($0.action)" }).contains("openRecording"))
    }

    @Test func redactionPlaceholdersStandApart() {
        let segments = ScreenModel.segments("I spoke with [NAME] about [the] budget [EMAIL].")
        #expect(segments.map(\.text) == ["I spoke with ", "[NAME]", " about [the] budget ", "[EMAIL]", "."])
        #expect(segments.map(\.token) == [false, true, false, true, false])
    }

    @Test func bitmapsBecomeHalfBlocks() {
        var bitmap = Bitmap(width: 2, height: 3)
        bitmap[0, 0] = RGB(0xFF0000)
        bitmap[0, 1] = RGB(0x00FF00)
        bitmap[1, 2] = RGB(0x0000FF)
        var canvas = Canvas(width: 2, height: 2, background: RGB(0x000000))
        canvas.draw(bitmap, x: 0, y: 0)
        #expect(canvas[0, 0] == Cell(char: "▀", fg: RGB(0xFF0000), bg: RGB(0x00FF00), bold: false))
        #expect(canvas[1, 0].char == " ")  // both pixels empty: left alone
        #expect(canvas[1, 1] == Cell(char: "▀", fg: RGB(0x0000FF), bg: RGB(0x000000), bold: false))
        #expect(PixelTitle.large.count == 10 && Set(PixelTitle.large.map(\.count)).count == 1)
        #expect(PixelTitle.small.count == 6 && Set(PixelTitle.small.map(\.count)).count == 1)
    }

    @Test func brailleWaveformsStayOneRowHigh() {
        let trace = ScreenModel.braille(ScreenModel.waveform((0..<600).map { sin(Float($0) / 5) }, count: 20))
        #expect(trace.count == 10)
        #expect(trace.unicodeScalars.allSatisfy { (0x2800...0x28FF).contains($0.value) })
    }
}

/// Collects what a control was called with, from any task.
final class Calls<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    func record(_ value: Value) { values.withLock { $0.append(value) } }
    var all: [Value] { values.withLock { $0 } }
}

@Suite struct KeyHandlingTests {
    let live = LiveState()
    let paused = PauseFlag()
    let saves: AsyncStream<Void>
    let stops: AsyncStream<Void>
    let choices: AsyncStream<Record.Next>
    let controls: LiveScreen.Controls
    let naming: AsyncStream<Void>.Continuation
    /// Recordings asked for: nil means the Open window.
    let opened = Calls<URL?>()
    let declined = Calls<Bool>()

    init() {
        let live = live
        let save: AsyncStream<Void>.Continuation
        let stop: AsyncStream<Void>.Continuation
        let choose: AsyncStream<Record.Next>.Continuation
        let (opened, declined) = (opened, declined)
        (saves, save) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        (stops, stop) = AsyncStream.makeStream(of: Void.self)
        (choices, choose) = AsyncStream.makeStream(of: Record.Next.self)
        controls = LiveScreen.Controls(
            paused: paused, begin: { live.update { $0.startedAt = Date() } }, stop: stop, save: save, choose: choose,
            openRecording: { opened.record($0) }, declined: { declined.record(true) })
        naming = AsyncStream.makeStream(of: Void.self).continuation
    }

    func press(_ keys: Key...) {
        for key in keys { LiveScreen.handle(key, live: live, controls: controls, finishNaming: naming) }
    }

    /// Types text key by key, as a person would.
    func type(_ text: String) {
        for char in text { press(.char(char)) }
    }

    /// How many times the meeting was asked to stop.
    func stopRequests() async -> Int {
        controls.stop.finish()
        var count = 0
        for await _ in stops { count += 1 }
        return count
    }

    @Test func recordingStartsOnlyOnceEveryoneHasAgreed() {
        press(.enter, .char("x"))  // no notes before recording begins
        #expect(!live.snapshot.started && live.snapshot.draft == nil && live.snapshot.notes.isEmpty)
        press(.char(" "))
        #expect(live.snapshot.askingConsent && !live.snapshot.started)
        press(.char("n"))  // not yet
        #expect(!live.snapshot.askingConsent && !live.snapshot.started && live.snapshot.consentedAt == nil)
        press(.char(" "), .char("q"))  // other keys don't answer the question
        #expect(live.snapshot.askingConsent)
        press(.char("y"))
        #expect(live.snapshot.started && live.snapshot.consentedAt != nil && !paused.isPaused)
        press(.char(" "))
        #expect(paused.isPaused && live.snapshot.paused && live.snapshot.draft == nil)
    }

    @Test func spaceAndF8PauseUnlessANoteIsUnderWay() {
        press(.char(" "), .char("y"))
        press(.char(" "))  // no note under way: pause...
        #expect(paused.isPaused && live.snapshot.draft == nil)
        press(.char(" "))  // ...and resume
        #expect(!paused.isPaused)
        type("call vendor")  // within a note, a space is a space
        #expect(!paused.isPaused && live.snapshot.draft?.text == "call vendor")
        press(.function(8))  // F8 pauses even partway through a note, which stays
        #expect(paused.isPaused && live.snapshot.draft?.text == "call vendor")
        press(.function(8))
        #expect(!paused.isPaused)
        press(.enter)
        #expect(live.snapshot.notes.map(\.text) == ["call vendor"])
        press(.char(" "))  // the note's added: Space pauses again
        #expect(paused.isPaused)
        press(.char(" "), .char("x"), .backspace)  // resume; then a note typed and rubbed out...
        #expect(!paused.isPaused && live.snapshot.draft == nil)
        press(.char(" "))  // ...leaves none under way, so Space pauses
        #expect(paused.isPaused)
        type("/pause")  // and the command works too
        press(.enter)
        #expect(!paused.isPaused)
    }

    @Test func sentencesTypedInAMeetingOnlyEverBecomeNotes() async {
        press(.char(" "), .char("y"))
        let look = live.snapshot.look
        let sentence = "quick question: please pause the vendor call? keep notes, name who's next /stop"
        type(sentence)
        let state = live.snapshot
        #expect(state.draft?.text == sentence)
        #expect(!state.paused && !paused.isPaused && state.look == look && state.naming == nil && !state.help)
        press(.enter)
        #expect(live.snapshot.notes.map(\.text) == [sentence])
        #expect(await stopRequests() == 0)
    }

    @Test func slashCommandsRunTheMeeting() async {
        live.update {
            $0.startedAt = Date()
            $0.turns = LookTests.snapshot().turns
        }
        let look = live.snapshot.look
        type("/pa")
        press(.enter)  // the only command that fits
        #expect(paused.isPaused)
        type("/resume")
        press(.enter)
        #expect(!paused.isPaused)
        type("/st")
        press(.tab)  // completes the name
        #expect(live.snapshot.draft?.text == "/stop")
        press(.escape)
        #expect(live.snapshot.draft == nil)
        type("/look")
        press(.enter)
        #expect(live.snapshot.look != look)
        type("/xyz")
        press(.enter)  // not a command: nothing happens, and it stays to be fixed
        #expect(live.snapshot.draft?.text == "/xyz" && live.snapshot.notes.isEmpty)
        press(.escape)
        type("/api is down again")
        press(.enter)  // a slash and more than a word is a note
        #expect(live.snapshot.notes.map(\.text) == ["/api is down again"])
        type("/name")
        press(.enter)
        #expect(live.snapshot.naming != nil)
        press(.escape)
        type("/help")
        press(.enter)
        #expect(live.snapshot.help)
        press(.char("x"))  // any key closes it
        #expect(!live.snapshot.help && live.snapshot.draft == nil)
        type("/stop")
        press(.enter)
        #expect(await stopRequests() == 1)
    }

    @Test func theSavedScreenStartsAnotherMeetingOrQuits() async throws {
        live.update { $0.saved = LiveState.Saved(path: "/tmp/minutes.md", turns: 3, speakers: 2) }
        press(.char(" "), .char("q"))
        var answers: [Record.Next] = []
        for await choice in choices {
            answers.append(choice)
            if answers.count == 2 { break }
        }
        #expect(answers == [.live, .quit])

        // Or a recording: chosen in the Open window, or dropped on the window.
        let folder = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let memo = try Fixtures.file("Team sync.m4a", in: folder)
        press(.char("o"), .paste(memo.path.replacingOccurrences(of: " ", with: "\\ ") + " "))
        #expect(opened.all == [nil, memo])
    }

    @Test func aRecordingCanBeOpenedInsteadOfRecording() throws {
        let folder = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let memo = try Fixtures.file("New Recording 4.m4a", in: folder)
        let notes = try Fixtures.file("notes.txt", in: folder)
        press(.char("o"))  // the Open window
        press(.paste("'\(memo.path)'"))  // dropped on the window
        #expect(opened.all == [nil, memo])
        press(.paste(notes.path))  // not a recording
        #expect(opened.all.count == 2 && live.snapshot.notice?.contains("notes.txt") == true)
        press(.paste("just some words"))
        #expect(opened.all.count == 2)

        // Not once recording has begun.
        press(.char(" "), .char("y"), .char("o"), .paste(memo.path))
        #expect(live.snapshot.started && opened.all.count == 2)
    }

    @Test func aRecordingIsTranscribedOnlyOnceEveryoneInItAgreed() {
        live.update {
            $0.recording = LiveState.Recording(name: "Team sync.m4a", length: 600)
            $0.askingConsent = true
        }
        press(.char("q"), .char("o"))  // other keys don't answer the question
        #expect(live.snapshot.askingConsent && opened.all.isEmpty && declined.all.isEmpty)
        press(.char("n"))
        #expect(!live.snapshot.started && declined.all.count == 1)
        live.update { $0.askingConsent = true }
        press(.char("y"))
        #expect(live.snapshot.started && live.snapshot.consentedAt != nil && declined.all.count == 1)
    }

    @Test func returnWritesANoteWhereTypingBegan() async {
        let (live, controls, saves) = (live, controls, saves)
        live.update { $0.elapsed = 10 }
        press(.char(" "), .char("y"))
        #expect(live.snapshot.draft == nil)
        live.update { $0.elapsed = 12 }  // typing starts two seconds later...
        press(.char("q"), .char("n"), .paste("\nnext steps"), .backspace)
        live.update { $0.elapsed = 30 }  // ...and ends much later
        #expect(live.snapshot.draft?.text == "qn next step")
        press(.enter)
        #expect(live.snapshot.notes == [Note(time: 12, text: "qn next step")])
        #expect(live.snapshot.draft == nil && !live.snapshot.stopping)
        controls.save.finish()
        var requested = 0
        for await _ in saves { requested += 1 }
        #expect(requested == 1)

        // Escape drops a note, and Return on an empty box adds nothing.
        press(.char("x"), .escape, .enter, .enter)
        #expect(live.snapshot.notes.count == 1 && live.snapshot.draft == nil)
    }
}

/// Files for tests, in a folder of their own that the test removes.
enum Fixtures {
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mmm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An empty file: enough for anything that only looks at names.
    static func file(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }
}

@Suite struct RecordingFileTests {
    @Test func droppedFilesArriveAsPathsInManyForms() throws {
        let folder = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let memo = try Fixtures.file("Team sync (final).m4a", in: folder)
        let escaped = memo.path.replacingOccurrences(of: " ", with: "\\ ").replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        for pasted in [
            memo.path,  // as is
            escaped + " ",  // Terminal: escaped, with a trailing space
            "'\(memo.path)'", "\"\(memo.path)\"",  // quoted
            memo.absoluteString,  // a file URL
            "\(escaped) \(escaped)",  // two files: the first
        ] {
            #expect(Recordings.url(fromPasted: pasted) == memo, "\(pasted)")
        }
        #expect(Recordings.url(fromPasted: folder.path) == nil)  // a folder
        #expect(Recordings.url(fromPasted: memo.path + ".missing") == nil)
        #expect(Recordings.url(fromPasted: "hello there") == nil)
    }

    @Test func recordingsAreKnownByTheirKind() {
        for name in ["a.m4a", "b.qta", "c.MP3", "d.wav", "e.mov", "f.aiff", "g.caf", "h.mp4"] {
            #expect(Recordings.isRecording(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.txt", "b.md", "c.pdf", "d"] {
            #expect(!Recordings.isRecording(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }
}

@Suite struct RecordingPartsTests {
    @Test func minutesNeverOverwriteEachOther() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mmm-unused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("2026-09-29 2114 Meeting.md")
        #expect(MinutesOptions.unused(first) == first)
        try "one".write(to: first, atomically: true, encoding: .utf8)
        let second = MinutesOptions.unused(first)
        #expect(second.lastPathComponent == "2026-09-29 2114 Meeting 2.md")
        try "two".write(to: second, atomically: true, encoding: .utf8)
        #expect(MinutesOptions.unused(first).lastPathComponent == "2026-09-29 2114 Meeting 3.md")
    }

    @Test func theClockStartsOnce() {
        let clock = RecordingClock()
        #expect(!clock.started && clock.seconds(to: HostTime.now()) == nil)
        #expect(clock.start())
        #expect(!clock.start())
        let seconds = clock.seconds(to: HostTime.now() + HostTime.ticks(2))!
        #expect(seconds > 1.9 && seconds < 2.5)
    }

    @Test func aMicrophoneThatArrivesAfterStoppingIsTurnedAway() {
        let slot = MicrophoneSlot()
        #expect(slot.put(MicrophoneCapture(onSamples: { _, _ in })))
        slot.close()
        #expect(!slot.put(MicrophoneCapture(onSamples: { _, _ in })))
    }
}

@Suite struct CarryNamesTests {
    @Test func namesFollowSpeechThroughRelabeling() {
        let liveRoom2 = SpeakerID(channel: .room, number: 2)
        let finalRoom1 = SpeakerID(channel: .room, number: 1)
        let origins = (0..<3).map { SegmentKey(channel: .room, window: $0, segment: 0) }
        var live = LiveState.Snapshot()
        live.names = [liveRoom2: "Priya"]
        live.turns = origins.map {
            Turn(channel: .room, speaker: liveRoom2, origin: $0, start: Double($0.window) * 10,
                 end: Double($0.window) * 10 + 5, text: "…")
        }
        let final = origins.map {
            Turn(channel: .room, speaker: finalRoom1, origin: $0, start: Double($0.window) * 10,
                 end: Double($0.window) * 10 + 5, text: "…")
        }
        #expect(Record.carryNames(from: live, to: final) == [finalRoom1: "Priya"])
    }
}
