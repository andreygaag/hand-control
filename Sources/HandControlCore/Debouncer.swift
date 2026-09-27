import Foundation

/// What one camera frame says about the hand.
public enum Observation: Equatable, Sendable {
    /// Hand clearly seen; nil label = classifier rejected the pose.
    case pose(String?)
    /// No hand in frame. This is how the user ends a gesture (hand back under the desk).
    case absent
    /// Tracking dropout (Vision error, low-confidence or partial hand). Carries no evidence
    /// of its own; see Debouncer for how dropouts are bridged.
    case unreliable
}

/// Turns a noisy per-frame observation stream into discrete fire events.
///
/// A label fires once it has been observed continuously for `hold`. It then latches: it
/// cannot fire again until a different label or no hand has been observed for `release`.
/// The release window absorbs classifier flicker, which would otherwise re-fire a held pose.
///
/// Dropout contract: unreliable frames are skipped, and a gap between reliable observations
/// of at most `maxGap` is interpolated — the state observed before the gap is assumed to
/// have lasted through it, so its time counts toward the running hold or release. A longer
/// gap breaks continuity and restarts both timers. Interpolation is deliberate: occluded
/// poses (a fist) may alternate reliable and unreliable frames and must still reach `hold`.
public struct Debouncer: Sendable {
    public let hold: TimeInterval
    public let release: TimeInterval
    public let maxGap: TimeInterval

    private var lastObserved: TimeInterval?
    private var candidate: String?
    private var candidateSince: TimeInterval = 0
    private var latched: String?
    private var latchedLostSince: TimeInterval?

    public init(hold: TimeInterval, release: TimeInterval, maxGap: TimeInterval) {
        self.hold = hold
        self.release = release
        self.maxGap = maxGap
    }

    /// Feed one frame. Returns the label to fire, if any.
    public mutating func update(_ observation: Observation, at time: TimeInterval) -> String? {
        let label: String?
        switch observation {
        case .unreliable: return nil
        case .absent: label = nil
        case .pose(let l): label = l
        }

        if let last = lastObserved, time - last > maxGap {
            candidate = nil
            candidateSince = time
            latchedLostSince = nil
        }
        lastObserved = time

        if let held = latched {
            if label == held {
                latchedLostSince = nil
            } else {
                let since = latchedLostSince ?? time
                latchedLostSince = since
                if time - since >= release {
                    latched = nil
                    latchedLostSince = nil
                }
            }
        }

        if label != candidate {
            candidate = label
            candidateSince = time
        }

        guard let c = candidate, c != latched, time - candidateSince >= hold else { return nil }
        latched = c
        latchedLostSince = nil
        return c
    }
}
