import Foundation

/// Keeps speaker labels consistent across a whole meeting without keeping any audio.
///
/// Each analysis window is diarized on its own. The diarizer's segmentation (where speaker
/// changes happen) is reliable, but its clustering sees only that window and can merge similar
/// voices. So every diarized segment gets its own voice embedding, and the linker clusters those
/// embeddings across the meeting: `link` assigns live labels as windows finish, and
/// `finalAssignment` refines all of them at the end (merging split speakers, moving misassigned
/// segments, folding stray fragments) so later evidence can correct early guesses.
///
/// The thresholds lean toward splitting: one person under two labels is recoverable (give both
/// the same name), two people under one label is not.
public struct SpeakerLinker: Sendable {
    /// A stretch of one speaker's speech inside a window.
    public struct Segment: Sendable {
        public let index: Int
        /// The window diarizer's speaker ID for this segment.
        public let local: String
        public let start: TimeInterval
        public let duration: Double
        /// Voice embedding, or nil when the segment was too short to embed reliably.
        public let embedding: [Float]?

        public init(index: Int, local: String, start: TimeInterval, duration: Double, embedding: [Float]?) {
            self.index = index
            self.local = local
            self.start = start
            self.duration = duration
            self.embedding = embedding
        }
    }

    public struct Thresholds: Sendable {
        /// Cosine similarity a segment needs to join an existing speaker.
        public var link: Float = 0.6
        /// ...when the segment is shorter than `shortSpeechSeconds` (noisier embedding).
        public var weakLink: Float = 0.45
        public var shortSpeechSeconds: Double = 2.0
        /// ...when the diarizer put a different local speaker in that cluster in the same window.
        public var otherLocalLink: Float = 0.7
        /// Similarity between two speakers' average voices above which they are merged at the end.
        public var merge: Float = 0.75
        /// Speakers with less total speech than this are folded into their closest match at the end.
        public var minSpeakerSeconds: Double = 3.0

        public init() {}
    }

    struct Item: Sendable {
        let key: SegmentKey
        let start: TimeInterval
        let embedding: [Float]
        let weight: Float
        var cluster: Int
    }

    public let channel: Channel
    public var thresholds: Thresholds

    /// Duration-weighted sums of unit embeddings; index + 1 is the live speaker number.
    private(set) var clusters: [[Float]] = []
    private(set) var items: [Item] = []
    /// Segments without embeddings, with the live cluster they were given.
    private var unembedded: [SegmentKey: Int] = [:]
    private var lastCluster: Int?

    public init(channel: Channel, thresholds: Thresholds = Thresholds()) {
        self.channel = channel
        self.thresholds = thresholds
    }

    public var speakerCount: Int { clusters.count }

    /// Assigns live labels to one window's segments, keyed by segment index.
    public mutating func link(window: Int, segments: [Segment]) -> [Int: SpeakerID] {
        var assignment: [Int: Int] = [:]
        var localsInCluster: [Int: Set<String>] = [:]
        let existingClusters = clusters.count

        // Longest segments first: their embeddings are the most reliable, so they anchor labels.
        for segment in segments.sorted(by: { $0.duration > $1.duration }) {
            guard let raw = segment.embedding else { continue }
            let embedding = Self.normalized(raw)
            let short = segment.duration < thresholds.shortSpeechSeconds
            let ranked = clusters.indices
                .map { ($0, Self.dot(embedding, Self.normalized(clusters[$0]))) }
                .sorted { $0.1 > $1.1 }

            var chosen: Int?
            for (cluster, similarity) in ranked {
                var required = short ? thresholds.weakLink : thresholds.link
                if let locals = localsInCluster[cluster], !locals.isEmpty, !locals.contains(segment.local) {
                    required = max(required, thresholds.otherLocalLink)
                }
                if similarity >= required {
                    chosen = cluster
                    break
                }
            }
            if chosen == nil, short {
                // Too short to judge by voice: trust the diarizer's grouping within the window.
                chosen = localsInCluster.first { $0.value.contains(segment.local) }?.key
            }
            let cluster = chosen ?? newCluster(dimension: embedding.count)

            let weight = Float(max(segment.duration, 0.1))
            add(embedding, weight: weight, to: cluster)
            items.append(
                Item(
                    key: SegmentKey(channel: channel, window: window, segment: segment.index),
                    start: segment.start, embedding: embedding, weight: weight, cluster: cluster))
            assignment[segment.index] = cluster
            localsInCluster[cluster, default: []].insert(segment.local)
        }

        // Segments without embeddings follow the diarizer's grouping, else the last speaker.
        for segment in segments.sorted(by: { $0.start < $1.start }) where segment.embedding == nil {
            let sameLocal = segments.filter { $0.local == segment.local }.compactMap { assignment[$0.index] }.first
            let cluster = sameLocal ?? lastCluster ?? newCluster(dimension: 0)
            assignment[segment.index] = cluster
            unembedded[SegmentKey(channel: channel, window: window, segment: segment.index)] = cluster
        }

        renumberNewClusters(from: existingClusters, assignment: &assignment, segments: segments)
        if let latest = segments.max(by: { $0.start < $1.start }), let cluster = assignment[latest.index] {
            lastCluster = cluster
        }
        return assignment.mapValues { SpeakerID(channel: channel, number: $0 + 1) }
    }

    /// Segments are matched longest-first, so speakers new in this window were created in that
    /// order. Renumber them by when they first spoke, so live labels follow speaking order just
    /// like the final ones.
    private mutating func renumberNewClusters(
        from firstNew: Int, assignment: inout [Int: Int], segments: [Segment]
    ) {
        guard clusters.count - firstNew > 1 else { return }
        let starts = Dictionary(uniqueKeysWithValues: segments.map { ($0.index, $0.start) })
        var firstStart: [Int: TimeInterval] = [:]
        for (segment, cluster) in assignment where cluster >= firstNew {
            firstStart[cluster] = min(firstStart[cluster] ?? .infinity, starts[segment] ?? .infinity)
        }
        let order = (firstNew..<clusters.count).sorted { (firstStart[$0] ?? .infinity) < (firstStart[$1] ?? .infinity) }
        var mapping: [Int: Int] = [:]
        for (offset, old) in order.enumerated() { mapping[old] = firstNew + offset }
        clusters = Array(clusters[..<firstNew]) + order.map { clusters[$0] }
        for index in items.indices {
            if let new = mapping[items[index].cluster] { items[index].cluster = new }
        }
        for (key, cluster) in unembedded {
            if let new = mapping[cluster] { unembedded[key] = new }
        }
        for (segment, cluster) in assignment {
            if let new = mapping[cluster] { assignment[segment] = new }
        }
    }

    /// Similarity of an embedding to each current speaker, for diagnostics.
    public func similarities(of embedding: [Float]) -> [Float] {
        let unit = Self.normalized(embedding)
        return clusters.map { Self.dot(unit, Self.normalized($0)) }
    }

    private mutating func newCluster(dimension: Int) -> Int {
        clusters.append([Float](repeating: 0, count: dimension))
        return clusters.count - 1
    }

    private mutating func add(_ embedding: [Float], weight: Float, to cluster: Int) {
        if clusters[cluster].count != embedding.count {
            clusters[cluster] = [Float](repeating: 0, count: embedding.count)
        }
        for index in embedding.indices { clusters[cluster][index] += embedding[index] * weight }
    }

    /// Refines every live label using the whole meeting and returns the final label for each
    /// segment, renumbered in order of first appearance.
    public func finalAssignment() -> [SegmentKey: SpeakerID] {
        var assignment = items.map(\.cluster)
        let clusterCount = clusters.count

        func centroids() -> (vectors: [[Float]], weights: [Float]) {
            let dimension = items.first?.embedding.count ?? 0
            var sums = [[Float]](repeating: [Float](repeating: 0, count: dimension), count: clusterCount)
            var weights = [Float](repeating: 0, count: clusterCount)
            for (index, item) in items.enumerated() {
                let cluster = assignment[index]
                for d in 0..<dimension { sums[cluster][d] += item.embedding[d] * item.weight }
                weights[cluster] += item.weight
            }
            return (sums.map(Self.normalized), weights)
        }

        for _ in 0..<10 {
            var changed = false

            // Merge speakers whose average voices are nearly the same.
            while true {
                let (vectors, weights) = centroids()
                var best: (a: Int, b: Int, similarity: Float)?
                for a in 0..<clusterCount where weights[a] > 0 {
                    for b in (a + 1)..<clusterCount where weights[b] > 0 {
                        let similarity = Self.dot(vectors[a], vectors[b])
                        if similarity >= thresholds.merge, similarity > (best?.similarity ?? -1) { best = (a, b, similarity) }
                    }
                }
                guard let best else { break }
                for index in assignment.indices where assignment[index] == best.b { assignment[index] = best.a }
                changed = true
            }

            // Move each segment to the speaker it sounds most like, if clearly better.
            let (vectors, weights) = centroids()
            for (index, item) in items.enumerated() {
                let current = assignment[index]
                let currentSimilarity = Self.dot(item.embedding, vectors[current])
                var best = (cluster: current, similarity: currentSimilarity)
                for cluster in 0..<clusterCount where weights[cluster] > 0 && cluster != current {
                    let similarity = Self.dot(item.embedding, vectors[cluster])
                    if similarity > best.similarity { best = (cluster, similarity) }
                }
                if best.cluster != current && best.similarity - currentSimilarity > 0.05 {
                    assignment[index] = best.cluster
                    changed = true
                }
            }

            // Fold speakers with only a few seconds of speech into their closest match, smallest first.
            var (folded, foldedWeights) = centroids()
            for cluster in (0..<clusterCount).sorted(by: { foldedWeights[$0] < foldedWeights[$1] }) {
                guard foldedWeights[cluster] > 0, Double(foldedWeights[cluster]) < thresholds.minSpeakerSeconds else {
                    continue
                }
                var target: (cluster: Int, similarity: Float)?
                for other in 0..<clusterCount where other != cluster && foldedWeights[other] > 0 {
                    let similarity = Self.dot(folded[cluster], folded[other])
                    if similarity >= thresholds.weakLink, similarity > (target?.similarity ?? -1) {
                        target = (other, similarity)
                    }
                }
                if let target {
                    for index in assignment.indices where assignment[index] == cluster { assignment[index] = target.cluster }
                    foldedWeights[target.cluster] += foldedWeights[cluster]
                    foldedWeights[cluster] = 0
                    folded[cluster] = []
                    changed = true
                }
            }
            if !changed { break }
        }

        // Number speakers by first appearance.
        var firstSeen: [Int: TimeInterval] = [:]
        for (index, item) in items.enumerated() {
            firstSeen[assignment[index]] = min(firstSeen[assignment[index]] ?? .infinity, item.start)
        }
        let order = firstSeen.keys.sorted { firstSeen[$0]! < firstSeen[$1]! }
        var number: [Int: Int] = [:]
        for (rank, cluster) in order.enumerated() { number[cluster] = rank + 1 }

        var result: [SegmentKey: SpeakerID] = [:]
        var liveToFinal: [Int: [Int: Float]] = [:]
        for (index, item) in items.enumerated() {
            let final = number[assignment[index]]!
            result[item.key] = SpeakerID(channel: channel, number: final)
            liveToFinal[item.cluster, default: [:]][final, default: 0] += item.weight
        }
        // Unembedded segments follow the final label most of their live speaker ended up with.
        var extra = order.count
        var extraNumbers: [Int: Int] = [:]
        for (key, live) in unembedded {
            if let votes = liveToFinal[live], let final = votes.max(by: { $0.value < $1.value })?.key {
                result[key] = SpeakerID(channel: channel, number: final)
            } else {
                if extraNumbers[live] == nil {
                    extra += 1
                    extraNumbers[live] = extra
                }
                result[key] = SpeakerID(channel: channel, number: extraNumbers[live]!)
            }
        }
        return result
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        for value in vector { norm += value * value }
        norm = norm.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for index in a.indices { sum += a[index] * b[index] }
        return sum
    }
}
