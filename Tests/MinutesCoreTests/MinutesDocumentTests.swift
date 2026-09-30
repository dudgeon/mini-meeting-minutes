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

    @Test func notesFollowTheParagraphTheyWereTypedDuring() {
        var doc = document([
            turn(.room, 1, 0, "Good morning."), turn(.room, 1, 3, "Let's start."), turn(.remote, 1, 6, "Hi."),
        ])
        doc.notes = [
            Note(time: 90, text: "Follow up by Friday"), Note(time: 2, text: "Ask about the budget"),
            Note(time: 5.5, text: "Dana joined"),
        ]
        // Room 1's two turns stay one paragraph, with the note typed between them after it.
        #expect(doc.blocks == [
            .speech(speaker: "Room 1", start: 0, text: "Good morning. Let's start."),
            .note(Note(time: 2, text: "Ask about the budget")),
            .note(Note(time: 5.5, text: "Dana joined")),
            .speech(speaker: "Remote 1", start: 6, text: "Hi."),
            .note(Note(time: 90, text: "Follow up by Friday")),
        ])
        #expect(doc.markdown().contains("Let's start.\n\n> **Note** · 00:00:02  \n> Ask about the budget\n\n> **Note**"))
        #expect(doc.paragraphs.count == 2)
    }

    @Test func notesWithoutSpeech() {
        var doc = document([])
        doc.notes = [Note(time: 65, text: "Nobody has joined yet")]
        #expect(doc.markdown().hasSuffix("---\n\n> **Note** · 00:01:05  \n> Nobody has joined yet\n"))
    }

    @Test func consentIsRecorded() {
        var doc = document([turn(.room, 1, 0, "Hello.")])
        #expect(!doc.markdown().contains("Consent"))
        doc.consentConfirmedAt = Date(timeIntervalSince1970: 0)
        #expect(doc.markdown().contains("- **Consent:** at "))
        #expect(doc.markdown().contains("had been told the conversation would be recorded and transcribed, and had agreed"))
    }

    @Test func minutesOfARecordingSayWhereTheyCameFrom() {
        var doc = document([turn(.room, 1, 0, "Hello.")])
        doc.recording = MinutesDocument.Recording(name: "Team sync.m4a", length: 125)
        doc.consentConfirmedAt = Date(timeIntervalSince1970: 0)
        var markdown = doc.markdown()
        #expect(markdown.contains("- **Audio:** the recording “Team sync.m4a”, which was only read\n"))
        #expect(markdown.contains("- **Duration:** 2 min\n"))
        #expect(markdown.contains("the person transcribing it confirmed that everyone in the recording had known"))
        #expect(!markdown.contains("microphone") && !markdown.contains("echo"))

        // Stopped partway through.
        doc.recording?.length = 3600
        markdown = doc.markdown()
        #expect(markdown.contains("- **Duration:** 2 min (stopped early; the recording runs 1 h 0 min)\n"))
        doc.inProgress = true
        #expect(doc.markdown().contains("> Transcribing in progress."))
    }

    @Test func timestamps() {
        #expect(MinutesDocument.timestamp(0) == "00:00:00")
        #expect(MinutesDocument.timestamp(59.9) == "00:00:59")
        #expect(MinutesDocument.timestamp(3725) == "01:02:05")
    }
}
