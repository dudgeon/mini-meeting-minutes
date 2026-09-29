import Foundation
import Testing

@testable import MinutesCore

@Suite struct MinutesDocumentTests {
    func turn(_ channel: Channel, _ number: Int, _ start: TimeInterval, _ text: String) -> Turn {
        Turn(
            channel: channel, speaker: SpeakerID(channel: channel, number: number),
            origin: SegmentKey(channel: channel, window: 0, segment: Int(start)), start: start, end: start + 2,
            text: text)
    }

    func document(_ turns: [Turn], names: [SpeakerID: String] = [:]) -> MinutesDocument {
        MinutesDocument(
            title: "Planning", startDate: Date(timeIntervalSince1970: 0), duration: 125,
            sources: [.room: "MacBook Pro Microphone", .remote: "system audio"], redaction: [.name, .email],
            echoCancellation: true, turns: turns, names: names, inProgress: false)
    }

    @Test func mergesConsecutiveTurnsBySameSpeaker() {
        let doc = document([
            turn(.room, 1, 0, "Good morning."),
            turn(.room, 1, 3, "Let's start."),
            turn(.remote, 1, 6, "Sounds good."),
            turn(.room, 1, 9, "First item."),
        ])
        #expect(doc.paragraphs.map(\.speaker) == ["Room 1", "Remote 1", "Room 1"])
        #expect(doc.paragraphs[0].text == "Good morning. Let's start.")
    }

    @Test func sameNameMergesSpeakers() {
        let doc = document(
            [turn(.room, 1, 0, "One."), turn(.room, 2, 3, "Two.")],
            names: [SpeakerID(channel: .room, number: 1): "Geoff", SpeakerID(channel: .room, number: 2): "Geoff"])
        #expect(doc.paragraphs.count == 1)
        #expect(doc.markdown().contains("- **Speakers:** Geoff\n"))
    }

    @Test func markdownLayout() {
        let markdown = document([turn(.remote, 2, 3725, "Hello.")]).markdown()
        #expect(markdown.hasPrefix("# Planning\n"))
        #expect(markdown.contains("- **Duration:** 2 min"))
        #expect(markdown.contains("microphone (MacBook Pro Microphone) and system audio (system audio), echo-cancelled"))
        #expect(markdown.contains("- **Redacted:** person names, email addresses"))
        #expect(markdown.contains("No audio was stored."))
        #expect(markdown.contains("**Remote 2** · 01:02:05  \nHello."))
    }

    @Test func timestamps() {
        #expect(MinutesDocument.timestamp(0) == "00:00:00")
        #expect(MinutesDocument.timestamp(59.9) == "00:00:59")
        #expect(MinutesDocument.timestamp(3725) == "01:02:05")
    }
}
