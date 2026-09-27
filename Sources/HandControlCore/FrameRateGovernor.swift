import Foundation

/// Chooses how often frames are fed to Vision: full rate while a hand may be present,
/// reduced rate after `idleAfter` of continuously observed absence. Any non-absent frame
/// (including an unreliable one) restores full rate immediately.
public struct FrameRateGovernor: Sendable {
    public let activeInterval: TimeInterval
    public let idleInterval: TimeInterval
    public let idleAfter: TimeInterval

    public private(set) var isIdle = false
    private var absentSince: TimeInterval?

    public init(activeFPS: Double, idleFPS: Double, idleAfter: TimeInterval) {
        precondition(activeFPS > 0 && idleFPS > 0 && idleFPS <= activeFPS)
        activeInterval = 1 / activeFPS
        idleInterval = 1 / idleFPS
        self.idleAfter = idleAfter
    }

    public var interval: TimeInterval { isIdle ? idleInterval : activeInterval }

    /// Feed one processed frame. Returns true when idle state changed.
    public mutating func update(handPresent: Bool, at time: TimeInterval) -> Bool {
        if handPresent {
            absentSince = nil
            guard isIdle else { return false }
            isIdle = false
            return true
        }
        let since = absentSince ?? time
        absentSince = since
        guard !isIdle, time - since >= idleAfter else { return false }
        isIdle = true
        return true
    }
}
