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

@Suite struct RetroViewTests {
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
        return state
    }

    static func render(_ state: LiveState.Snapshot, _ width: Int, _ height: Int) -> Canvas {
        RetroView.render(
            state, skin: .classic, analyzers: [.room: SpectrumAnalyzer(), .remote: SpectrumAnalyzer()], width: width,
            height: height, time: 1, frameInterval: 0.05
        ).canvas
    }

    static func text(_ canvas: Canvas) -> String {
        String(canvas.cells.map(\.char))
    }

    @Test(arguments: [(120, 42), (100, 36), (80, 26), (60, 16), (30, 8)])
    func rendersEveryLayout(size: (Int, Int)) {
        let canvas = Self.render(Self.snapshot(), size.0, size.1)
        let text = Self.text(canvas)
        if size.0 >= 50 {
            #expect(text.contains("TRANSCRIPT"))
            #expect(text.contains("Good morning everyone."))
            #expect(text.contains("ROOM …"))
        } else {
            #expect(text.contains("Make this window bigger"))
        }
        #expect(text.contains("WHO SPOKE WHEN") == (size.0 >= 100 && size.1 >= 36))
    }

    @Test func dialogsAndButtons() {
        var state = Self.snapshot()
        state.naming = LiveState.Naming(speakers: [SpeakerID(channel: .room, number: 1)])
        state.names = [SpeakerID(channel: .room, number: 1): "Priya"]
        let canvas = Self.render(state, 120, 42)
        #expect(Self.text(canvas).contains("WHO WAS SPEAKING?"))
        #expect(Self.text(canvas).contains("Priya"))
        let actions = Set(canvas.regions.map { "\($0.action)" })
        #expect(actions.isSuperset(of: ["stop", "pause", "name", "visualizer", "skin", "help"]))
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
