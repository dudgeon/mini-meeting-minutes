import Foundation

/// The markdown minutes file: a short header followed by the attributed transcript.
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
    /// While recording, labels can still change; the header says so.
    public var inProgress: Bool

    public init(
        title: String, startDate: Date, duration: TimeInterval = 0, sources: [Channel: String],
        redaction: Set<PIICategory>, echoCancellation: Bool, turns: [Turn] = [], names: [SpeakerID: String] = [:],
        inProgress: Bool = true
    ) {
        self.title = title
        self.startDate = startDate
        self.duration = duration
        self.sources = sources
        self.redaction = redaction
        self.echoCancellation = echoCancellation
        self.turns = turns
        self.names = names
        self.inProgress = inProgress
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

    /// Consecutive turns by the same person, merged into paragraphs. Speakers given the same name
    /// count as one person.
    public var paragraphs: [(speaker: String, start: TimeInterval, text: String)] {
        var result: [(speaker: String, start: TimeInterval, end: TimeInterval, text: String)] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let speaker = name(of: turn.speaker)
            // Same speaker again soon after: continue the paragraph, but start a fresh,
            // timestamped one every couple of minutes so long monologues stay navigable.
            if let last = result.last, last.speaker == speaker, turn.start - last.end < 30,
                turn.start - last.start < 120
            {
                result[result.count - 1].text += " " + turn.text
                result[result.count - 1].end = max(last.end, turn.end)
            } else {
                result.append((speaker, turn.start, turn.end, turn.text))
            }
        }
        return result.map { ($0.speaker, $0.start, $0.text) }
    }

    public func markdown() -> String {
        var lines: [String] = ["# \(title)", ""]
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        lines.append("- **Date:** \(dateFormatter.string(from: startDate))")
        lines.append("- **Duration:** \(Self.durationText(duration))")

        let audio = Channel.allCases.compactMap { channel -> String? in
            guard let source = sources[channel] else { return nil }
            return channel == .room ? "microphone (\(source))" : "system audio (\(source))"
        }
        lines.append("- **Audio:** \(audio.joined(separator: " and "))" + (echoCancellation ? ", echo-cancelled" : ""))

        var speakerNames: [String] = []
        for speaker in speakers where !speakerNames.contains(name(of: speaker)) {
            speakerNames.append(name(of: speaker))
        }
        lines.append("- **Speakers:** \(speakerNames.isEmpty ? "none yet" : speakerNames.joined(separator: ", "))")
        let redacted = PIICategory.allCases.filter(redaction.contains).map(\.displayName)
        lines.append("- **Redacted:** \(redacted.isEmpty ? "nothing (redaction off)" : redacted.joined(separator: ", "))")
        lines.append("")
        lines.append(
            inProgress
                ? "> Recording in progress. Speaker labels may change when the meeting ends."
                : "> Transcribed on this Mac by mini-meeting-minutes. No audio was stored.")
        lines.append("")
        lines.append("---")

        for paragraph in paragraphs {
            lines.append("")
            lines.append("**\(paragraph.speaker)** · \(Self.timestamp(paragraph.start))  ")
            lines.append(paragraph.text)
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
