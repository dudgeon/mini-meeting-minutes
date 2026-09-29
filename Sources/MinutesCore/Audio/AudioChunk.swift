import Foundation

/// Where audio comes from. Each channel is transcribed and diarized independently, so remote
/// participants and people in the room never share a speaker label.
public enum Channel: String, Sendable, CaseIterable, Codable, Comparable {
    /// The microphone: people in the room.
    case room
    /// System audio output: remote participants on a call.
    case remote

    public var label: String {
        switch self {
        case .room: "Room"
        case .remote: "Remote"
        }
    }

    public static func < (lhs: Channel, rhs: Channel) -> Bool {
        lhs == .room && rhs == .remote
    }
}

/// Mono 16 kHz Float32 samples, stamped with the session time (seconds since recording started)
/// of the first sample.
public struct AudioChunk: Sendable {
    public static let sampleRate = 16_000
    public static let samplesPerSecond = Double(sampleRate)

    public var samples: [Float]
    public var time: TimeInterval

    public init(samples: [Float], time: TimeInterval) {
        self.samples = samples
        self.time = time
    }

    public var duration: TimeInterval { Double(samples.count) / Self.samplesPerSecond }
    public var endTime: TimeInterval { time + duration }

    /// Root-mean-square level, for meters.
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
