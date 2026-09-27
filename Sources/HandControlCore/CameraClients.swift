import Foundation

/// Who else is using the camera, reconstructed from the camera daemon's log messages
/// (`appleh13camerad` on M3; `process ENDSWITH "camerad"` in general).
///
/// There is no public API for this. The messages below are undocumented, verified only on
/// the built-in FaceTime HD camera under macOS 26, and may change with any OS update. What
/// they allow:
/// - `connected`: processes attached to the camera daemon. Attaching happens on mere device
///   discovery and ends only when the process exits — "connected" is not "reading".
/// - `activeStreams`: running streams, counted from the daemon's system-status attribution
///   messages (pid redacted). Not from "start/stop streaming": a client killed mid-stream
///   logs no stop, but its attribution is still removed when it disconnects. A clean stop
///   removes it at stop time; the later "Couldn't find attribution to remove" is ignored.
///   Includes our own stream.
/// - `startedStream`: pids seen requesting camera access, which the daemon does on a
///   process's first stream start only. Info-level, so live stream only, not history.
public struct CameraClients: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case connected(Int32)
        case disconnected(Int32)
        case streamRequested(Int32)
        case streamStarted
        case streamStopped
    }

    public private(set) var connected: Set<Int32> = []
    public private(set) var startedStream: Set<Int32> = []
    public private(set) var activeStreams = 0

    public init() {}

    public static func parse(_ message: String) -> Event? {
        if let pid = pid(after: "ConnectClient: Added client [", in: message) { return .connected(pid) }
        if let pid = pid(after: "DisconnectClient: Removed client [", in: message) { return .disconnected(pid) }
        if message.contains("service=kTCCServiceCamera"),
           let pid = pid(after: "target_token={pid:", in: message) { return .streamRequested(pid) }
        if message.contains("added attribution <") { return .streamStarted }
        if message.contains("Removed attribution <") { return .streamStopped }
        return nil
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .connected(let pid):
            connected.insert(pid)
        case .disconnected(let pid):
            connected.remove(pid)
            startedStream.remove(pid)
        case .streamRequested(let pid):
            startedStream.insert(pid)
        case .streamStarted:
            activeStreams += 1
        case .streamStopped:
            // History starts mid-session, so a stop can precede its start in our view.
            activeStreams = max(0, activeStreams - 1)
        }
    }

    /// The system reports no camera running anywhere: every counted stream is stale (e.g. a
    /// client crashed without a stop message). Only meaningful while we are not streaming.
    public mutating func reconcileNothingRunning() {
        activeStreams = 0
    }

    /// Streams not owned by us.
    public func foreignStreams(own: Int) -> Int { max(0, activeStreams - own) }

    /// Connected processes other than `me`: those seen starting a stream first, then by pid.
    public func candidates(excluding me: Int32) -> [Int32] {
        connected.subtracting([me]).sorted {
            let a = startedStream.contains($0), b = startedStream.contains($1)
            return a != b ? a : $0 < $1
        }
    }

    private static func pid(after prefix: String, in message: String) -> Int32? {
        guard let range = message.range(of: prefix) else { return nil }
        let digits = message[range.upperBound...].prefix { $0.isNumber }
        return Int32(digits)
    }
}
