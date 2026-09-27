import Foundation

public struct HandControlError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Where data, config and the event log live. Shared by the CLI and the menu bar app.
public struct Paths: Sendable {
    public let dataDir: URL
    public let gestures: URL
    public let config: URL
    public let eventLog: URL
    /// Held by whichever process is running the engine: CLI `run` and the app together
    /// would fire every action twice.
    public let lock: URL

    public init(environment: [String: String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = environment["HAND_CONTROL_DIR"].map { URL(fileURLWithPath: $0) }
        dataDir = override ?? home.appendingPathComponent(".config/hand-control")
        gestures = dataDir.appendingPathComponent("gestures.json")
        config = dataDir.appendingPathComponent("config.json")
        lock = dataDir.appendingPathComponent("run.lock")
        // ~/Library/Logs is where Console.app looks; an explicit data dir keeps test runs isolated.
        eventLog = override != nil
            ? dataDir.appendingPathComponent("hand-control.log")
            : home.appendingPathComponent("Library/Logs/hand-control.log")
    }

    public static let current = Paths(environment: ProcessInfo.processInfo.environment)
}

public func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private let eventTimestamp = Date.ISO8601FormatStyle(
    dateTimeSeparator: .space, includingFractionalSeconds: true, timeZone: .current)

/// Significant events (start/stop, fires, mode changes, errors) go to stderr and to
/// `Paths.current.eventLog`; per-frame chatter goes to stderr only. Each line is one
/// O_APPEND write, so lines from different threads do not interleave. No rotation:
/// volume is a few lines per gesture.
public func event(_ message: String) {
    log(message)
    let line = "\(Date().formatted(eventTimestamp)) \(message)\n"
    let fd = open(Paths.current.eventLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
}

/// Exclusive flock on a file, held until the process exits or the lock is released (the
/// kernel releases it even on a crash, so there are no stale locks). Records the owner pid
/// for the error message. O_CLOEXEC keeps children (`log stream`, `pmset`) from inheriting
/// the descriptor — an orphaned child would otherwise hold the lock after we quit.
public final class InstanceLock: Sendable {
    private let fd: Int32

    public init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw HandControlError("cannot open \(url.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // Empty when read between the owner's truncate and write.
            let owner = (try? String(contentsOf: url, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            close(fd)
            throw HandControlError("hand-control is already running (pid \(owner.flatMap { $0.isEmpty ? nil : $0 } ?? "?")): quit the Hand Control app or stop `hand-control run` first")
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
    }

    deinit { close(fd) }
}

/// Tracking rates and timing shared by `run` and `record`.
public enum Tuning {
    /// Frames per second fed to Vision (and requested from the camera).
    public static let trackingFPS = 15.0
    /// Rate after `minIdleAfter` without a hand. Waking costs up to one idle interval (0.5 s)
    /// before the hold starts.
    public static let idleFPS = 2.0
    /// Idle frames are farther apart than `maxObservationGap`, and every such gap restarts
    /// the release timer. A latched pose must therefore finish its release at the active
    /// rate before going idle, so idling waits for at least release + 1 s.
    public static let minIdleAfter: TimeInterval = 3
    /// Unobserved time after which a hold or release loses continuity (~3 frames at 15 fps).
    public static let maxObservationGap: TimeInterval = 0.25
    /// Minimum spacing between recorded samples: consecutive frames are near-duplicates.
    public static let recordInterval: TimeInterval = 0.2
}
