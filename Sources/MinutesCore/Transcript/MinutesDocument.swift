import Foundation

/// The markdown minutes file: a short header followed by the attributed transcript, with any
/// notes taken during the meeting in their place.
public struct MinutesDocument: Sendable {
    public var title: String
    public var startDate: Date
    public var duration: TimeInterval
    /// What each captured channel was, e.g. "MacBook Pro Microphone".
    public var sources: [Channel: String]
    public var redaction: Set<PIICategory>
    public var echoCancellation: Bool
    public var turns: [Turn]
    /// Names given to speakers; unnamed speakers keep their "Room 1" style label.
    public var names: [SpeakerID: String]
    public var notes: [Note]
    /// When the person recording confirmed that everyone taking part knew and agreed.
    public var consentConfirmedAt: Date?
    /// While recording, labels can still change; the header says so.
    public var inProgress: Bool
    /// Set when the minutes come from a recording someone already had, rather than a live meeting.
    public var recording: Recording?

    /// A recording transcribed after the fact: its file name, and how long it runs (the minutes
    /// may cover less, if transcribing was stopped early).
    public struct Recording: Sendable, Equatable {
        public var name: String
        public var length: TimeInterval

        public init(name: String, length: TimeInterval) {
            self.name = name
            self.length = length
        }
    }

    public init(
        title: String, startDate: Date, duration: TimeInterval = 0, sources: [Channel: String],
        redaction: Set<PIICategory>, echoCancellation: Bool, turns: [Turn] = [], names: [SpeakerID: String] = [:],
        notes: [Note] = [], consentConfirmedAt: Date? = nil, inProgress: Bool = true, recording: Recording? = nil
    ) {
        self.title = title
        self.startDate = startDate
        self.duration = duration
        self.sources = sources
        self.redaction = redaction
        self.echoCancellation = echoCancellation
        self.turns = turns
        self.names = names
        self.notes = notes
        self.consentConfirmedAt = consentConfirmedAt
        self.inProgress = inProgress
        self.recording = recording
    }

    public func name(of speaker: SpeakerID) -> String {
        if let name = names[speaker]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return speaker.description
    }

    /// Speakers in order of first appearance.
    public var speakers: [SpeakerID] {
        var seen = Set<SpeakerID>()
        return turns.sorted { $0.start < $1.start }.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    /// One piece of the transcript: a paragraph of speech, or a note.
    public enum Block: Sendable, Equatable {
        case speech(speaker: String, start: TimeInterval, text: String)
        case note(Note)
    }

    /// The transcript in time order. Consecutive turns by the same person are merged into
    /// paragraphs (speakers given the same name count as one person). A note never splits a
    /// paragraph: one typed while someone was talking follows the paragraph, keeping its own time.
    public var blocks: [Block] {
        var blocks: [Block] = []
        var paragraphEnd: TimeInterval = 0
        let notes = self.notes.sorted { $0.time < $1.time }
        var next = 0
        var held: [Note] = []  // typed during the open paragraph
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            while next < notes.count && notes[next].time < turn.start {
                held.append(notes[next])
                next += 1
            }
            let speaker = name(of: turn.speaker)
            // Same speaker again soon after: continue the paragraph, but start a fresh,
            // timestamped one every couple of minutes so long monologues stay navigable.
            if case .speech(let last, let start, let text)? = blocks.last, last == speaker,
                turn.start - paragraphEnd < 30, turn.start - start < 120
            {
                blocks[blocks.count - 1] = .speech(speaker: speaker, start: start, text: text + " " + turn.text)
                paragraphEnd = max(paragraphEnd, turn.end)
            } else {
                blocks += held.map { .note($0) }
                held = []
                blocks.append(.speech(speaker: speaker, start: turn.start, text: turn.text))
                paragraphEnd = turn.end
            }
        }
        blocks += (held + notes[next...]).map { .note($0) }
        return blocks
    }

    /// Just the paragraphs of speech.
    public var paragraphs: [(speaker: String, start: TimeInterval, text: String)] {
        blocks.compactMap { block in
            guard case .speech(let speaker, let start, let text) = block else { return nil }
            return (speaker, start, text)
        }
    }

    public func markdown() -> String {
        var lines: [String] = ["# \(title)", ""]
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        lines.append("- **Date:** \(dateFormatter.string(from: startDate))")
        if let recording, !inProgress, recording.length - duration > 1 {
            lines.append(
                "- **Duration:** \(Self.durationText(duration)) (stopped early; the recording runs "
                    + "\(Self.durationText(recording.length)))")
        } else {
            lines.append("- **Duration:** \(Self.durationText(duration))")
        }

        if let recording {
            lines.append("- **Audio:** the recording “\(recording.name)”, which was only read")
        } else {
            let audio = Channel.allCases.compactMap { channel -> String? in
                guard let source = sources[channel] else { return nil }
                return channel == .room ? "microphone (\(source))" : "system audio (\(source))"
            }
            lines.append(
                "- **Audio:** \(audio.joined(separator: " and "))" + (echoCancellation ? ", echo-cancelled" : ""))
        }

        var speakerNames: [String] = []
        for speaker in speakers where !speakerNames.contains(name(of: speaker)) {
            speakerNames.append(name(of: speaker))
        }
        lines.append("- **Speakers:** \(speakerNames.isEmpty ? "none yet" : speakerNames.joined(separator: ", "))")
        let redacted = PIICategory.allCases.filter(redaction.contains).map(\.displayName)
        lines.append("- **Redacted:** \(redacted.isEmpty ? "nothing (redaction off)" : redacted.joined(separator: ", "))")
        if let consentConfirmedAt {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            if recording != nil {
                // Transcribed later, maybe much later: the confirmation's own date matters.
                timeFormatter.dateStyle = .medium
                lines.append(
                    "- **Consent:** on \(timeFormatter.string(from: consentConfirmedAt)), the person transcribing it "
                        + "confirmed that everyone in the recording had known it was being recorded, and had agreed "
                        + "to it being transcribed")
            } else {
                timeFormatter.dateStyle = .none
                lines.append(
                    "- **Consent:** at \(timeFormatter.string(from: consentConfirmedAt)), the person recording "
                        + "confirmed that everyone taking part had been told the conversation would be recorded and "
                        + "transcribed, and had agreed")
            }
        }
        lines.append("")
        lines.append(
            inProgress
                ? recording == nil
                    ? "> Recording in progress. Speaker labels may change when the meeting ends."
                    : "> Transcribing in progress. Speaker labels may change when it's done."
                : "> Transcribed on this Mac by mini-meeting-minutes. No audio was stored.")
        lines.append("")
        lines.append("---")

        for block in blocks {
            lines.append("")
            switch block {
            case .speech(let speaker, let start, let text):
                lines.append("**\(speaker)** · \(Self.timestamp(start))  ")
                lines.append(text)
            case .note(let note):
                lines.append("> **Note** · \(Self.timestamp(note.time))  ")
                lines.append("> \(note.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes atomically, so a reader never sees a half-written file.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown().write(to: url, atomically: true, encoding: .utf8)
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
