import Foundation
import MinutesCore
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
        #expect(actions.isSuperset(of: ["stop", "pause", "name", "visualizer", "skin", "help"]))
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
