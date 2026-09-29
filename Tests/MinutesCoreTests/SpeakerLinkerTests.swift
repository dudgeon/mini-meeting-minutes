import Foundation
import Testing

@testable import MinutesCore

/// Synthetic voices: each speaker is a random unit vector; each segment is that voice plus noise.
@Suite struct SpeakerLinkerTests {
    struct Voices {
        var generator = SeededGenerator(seed: 7)

        mutating func voice() -> [Float] {
            SpeakerLinker.normalized((0..<256).map { _ in Float.random(in: -1...1, using: &generator) })
        }

        /// A voice whose cosine similarity to `base` is about `similarity`.
        mutating func voice(near base: [Float], similarity: Float) -> [Float] {
            let other = voice()
            let mix = (1 - similarity * similarity).squareRoot()
            return SpeakerLinker.normalized(zip(base, other).map { similarity * $0 + mix * $1 })
        }

        mutating func sample(_ voice: [Float], noise: Float = 0.35) -> [Float] {
            SpeakerLinker.normalized(voice.map { $0 + noise * Float.random(in: -1...1, using: &generator) / 16 })
        }
    }

    typealias Say = (voice: Int, start: TimeInterval, duration: Double)

    /// Links windows of segments; returns live labels and final labels per (window, segment).
    func run(_ windows: [[Say]], voices: [[Float]], noise: Float = 0.35) -> (live: [[Int]], final: [[Int]]) {
        var generator = Voices()
        var linker = SpeakerLinker(channel: .room)
        var live: [[Int]] = []
        for (window, says) in windows.enumerated() {
            let segments = says.enumerated().map { index, say in
                SpeakerLinker.Segment(
                    index: index, local: "S\(say.voice)", start: say.start, duration: say.duration,
                    embedding: generator.sample(voices[say.voice], noise: noise))
            }
            let labels = linker.link(window: window, segments: segments)
            live.append(segments.map { labels[$0.index]!.number })
        }
        let final = linker.finalAssignment()
        let finalLabels = windows.enumerated().map { window, says in
            says.indices.map { final[SegmentKey(channel: .room, window: window, segment: $0)]!.number }
        }
        return (live, finalLabels)
    }

    @Test func consistentLabelsAcrossWindows() {
        var voices = Voices()
        let people = [voices.voice(), voices.voice(), voices.voice()]
        let windows: [[Say]] = [
            [(0, 0, 6), (1, 7, 5), (0, 13, 4)],
            [(2, 31, 8), (1, 40, 6)],
            [(0, 62, 5), (2, 68, 7), (1, 76, 3)],
        ]
        let result = run(windows, voices: people)
        let expected = [[1, 2, 1], [3, 2], [1, 3, 2]]
        #expect(result.live == expected)
        #expect(result.final == expected)
    }

    @Test func keepsSimilarVoicesApart() {
        var voices = Voices()
        let first = voices.voice()
        // Like two similar synthetic voices measured at about 0.5 cosine similarity.
        let second = voices.voice(near: first, similarity: 0.5)
        let windows: [[Say]] = [[(0, 0, 7), (0, 8, 6), (1, 15, 8)], [(1, 31, 6), (0, 38, 6)]]
        let result = run(windows, voices: [first, second])
        #expect(result.final == [[1, 1, 2], [2, 1]])
    }

    @Test func foldsFragmentsIntoTheirSpeaker() {
        var voices = Voices()
        let people = [voices.voice(), voices.voice()]
        var linker = SpeakerLinker(channel: .remote)
        var generator = Voices(generator: SeededGenerator(seed: 99))
        let segments = [
            SpeakerLinker.Segment(index: 0, local: "S1", start: 0, duration: 8, embedding: generator.sample(people[0])),
            SpeakerLinker.Segment(index: 1, local: "S2", start: 9, duration: 8, embedding: generator.sample(people[1])),
            // Too short to embed: follows the diarizer's grouping.
            SpeakerLinker.Segment(index: 2, local: "S2", start: 18, duration: 0.3, embedding: nil),
        ]
        let live = linker.link(window: 0, segments: segments)
        #expect(live[2] == live[1])
        let final = linker.finalAssignment()
        #expect(final[SegmentKey(channel: .remote, window: 0, segment: 2)]?.number == 2)
    }

    @Test func mergesASpeakerSplitByANoisyStart() {
        var voices = Voices()
        let person = voices.voice()
        let stranger = voices.voice(near: person, similarity: 0.55)
        var linker = SpeakerLinker(channel: .room)
        var generator = Voices(generator: SeededGenerator(seed: 3))
        // A first segment that sounds unlike the rest (noise, a cough) opens its own speaker...
        _ = linker.link(
            window: 0,
            segments: [
                .init(index: 0, local: "S1", start: 0, duration: 2.5, embedding: stranger),
                .init(index: 1, local: "S1", start: 3, duration: 8, embedding: generator.sample(person)),
            ])
        _ = linker.link(
            window: 1,
            segments: [.init(index: 0, local: "S1", start: 31, duration: 9, embedding: generator.sample(person))])
        // ...but with less than `minSpeakerSeconds` of speech it's folded back in at the end.
        let final = linker.finalAssignment()
        #expect(Set(final.values.map(\.number)) == [1])
    }
}

/// Deterministic random numbers so tests are repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
