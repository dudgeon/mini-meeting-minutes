import Foundation

/// A recognized word with session-relative timing. Word text is never redacted, so words stay
/// inside the pipeline and are dropped once their turn has been redacted.
public struct Word: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public var midpoint: TimeInterval { (start + end) / 2 }
}

/// A speaker label: "Room 2", "Remote 1". Numbers are 1-based and count within a channel, in
/// order of first appearance.
public struct SpeakerID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let channel: Channel
    public let number: Int

    public init(channel: Channel, number: Int) {
        self.channel = channel
        self.number = number
    }

    public var description: String { "\(channel.label) \(number)" }

    public static func < (lhs: SpeakerID, rhs: SpeakerID) -> Bool {
        lhs.channel == rhs.channel ? lhs.number < rhs.number : lhs.channel < rhs.channel
    }
}

/// Identifies one diarized segment (a stretch of one person's speech) inside an analysis window.
/// The end-of-meeting relabeling maps these to final `SpeakerID`s.
public struct SegmentKey: Hashable, Sendable {
    public let channel: Channel
    public let window: Int
    public let segment: Int

    public init(channel: Channel, window: Int, segment: Int) {
        self.channel = channel
        self.window = window
        self.segment = segment
    }
}

/// Consecutive speech attributed to one speaker. `text` is already redacted when redaction is on.
public struct Turn: Sendable, Identifiable {
    public let id = UUID()
    public let channel: Channel
    public var speaker: SpeakerID
    public let origin: SegmentKey
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(
        channel: Channel, speaker: SpeakerID, origin: SegmentKey, start: TimeInterval,
        end: TimeInterval, text: String
    ) {
        self.channel = channel
        self.speaker = speaker
        self.origin = origin
        self.start = start
        self.end = end
        self.text = text
    }
}

extension Array where Element == Word {
    /// Joins words the way the recognizer emitted them: tokens carry their own punctuation.
    public var joinedText: String { map(\.text).joined(separator: " ") }
}
