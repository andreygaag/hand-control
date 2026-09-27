public struct Classification: Equatable, Sendable {
    /// Winning label, or nil when no sample lies within `maxDistance`.
    public let label: String?
    /// Label of the closest sample; useful for tuning `maxDistance` when rejected.
    public let candidate: String
    /// Distance to the closest sample of `label` (or of `candidate` when rejected).
    public let distance: Double
}

/// k-nearest-neighbours over recorded poses. Only neighbours within `maxDistance` vote:
/// otherwise several far samples of one label outvote a close sample of another and the
/// far label fires. Every recorded label takes part in the vote,
/// including labels with no binding: recording a "none" class of idle poses gives the
/// classifier an explicit reject class.
public struct Classifier: Sendable {
    public let k: Int
    public let maxDistance: Double
    private let samples: [(label: String, vector: [Double])]

    public init(samples: [String: [[Point]]], k: Int = 5, maxDistance: Double) {
        precondition(k > 0)
        self.k = k
        self.maxDistance = maxDistance
        self.samples = samples.keys.sorted().flatMap { label in
            samples[label, default: []].compactMap { pose in
                Features.vector(from: pose).map { (label: label, vector: $0) }
            }
        }
    }

    public var isEmpty: Bool { samples.isEmpty }

    public func classify(_ vector: [Double]) -> Classification? {
        guard !samples.isEmpty else { return nil }
        let nearest = samples
            .map { (label: $0.label, distance: Features.distance($0.vector, vector)) }
            .sorted { $0.distance < $1.distance }
            .prefix(k)

        let closest = nearest.first!
        let voters = nearest.filter { $0.distance <= maxDistance }
        guard !voters.isEmpty else {
            return Classification(label: nil, candidate: closest.label, distance: closest.distance)
        }

        var votes: [String: Int] = [:]
        for n in voters { votes[n.label, default: 0] += 1 }
        let top = votes.values.max()!
        // Ties go to the label that owns the closest sample: `voters` is sorted.
        let winner = voters.first { votes[$0.label] == top }!
        return Classification(label: winner.label, candidate: winner.label, distance: winner.distance)
    }

    /// For each label, the smallest distance from any of its samples to a sample of
    /// another label. Small values mean two gestures are easy to confuse.
    public func separation() -> [String: Double] {
        var result: [String: Double] = [:]
        for a in samples {
            for b in samples where b.label != a.label {
                let d = Features.distance(a.vector, b.vector)
                result[a.label] = min(result[a.label] ?? .infinity, d)
            }
        }
        return result
    }
}
