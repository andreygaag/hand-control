import AppKit
import CoreMediaIO
import HandControlCore

/// Best-effort answer to "who else is reading the camera", from the camera daemon's log.
/// See CameraClients for what the log can and cannot tell and CameraLogReplay for how
/// history and live output are merged; nothing here is public API.
///
/// `log stream` starts first, then `log show --last 1h` runs in the background, so a
/// snapshot never waits for history: until it arrives, `loading` is true. Streams and
/// connections older than the history window are missed until they restart.
///
/// @unchecked Sendable: mutable state is guarded by `lock`; callbacks never hold it while
/// blocking on anything but the in-memory replay.
public final class CameraMonitor: @unchecked Sendable {
    public struct Client: Hashable, Sendable {
        public let pid: Int32
        public let name: String
        public let startedStream: Bool
    }

    public struct Snapshot: Sendable {
        public let loading: Bool
        public let foreignStreams: Int
        public let candidates: [Client]
        public let error: String?
    }

    private static let predicate = #"process ENDSWITH "camerad" AND (eventMessage CONTAINS "Client: " OR eventMessage CONTAINS "TCCAccessRequest" OR eventMessage CONTAINS "attribution <")"#
    private static let history = "1h"
    /// `log show` normally takes 2–3 s for an hour; past this it is abandoned.
    private static let historyTimeout: TimeInterval = 20
    private static let restartDelay: TimeInterval = 5

    private let lock = NSLock()
    private var replay = CameraLogReplay()
    private var stream: Process?
    private var stopped = false
    private var error: String?

    public init() {}

    public func start() {
        startStream()
        DispatchQueue.global(qos: .utility).async { self.loadHistory() }
    }

    /// Terminates `log stream` before returning, so a caller that exits right after
    /// (CLI, app termination) leaves no orphan behind.
    public func stop() {
        let process = lock.withLock {
            stopped = true
            defer { stream = nil }
            return stream
        }
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
    }

    /// `engineStreaming`: this process itself holds a camera stream, which the log counts too.
    public func snapshot(engineStreaming: Bool) -> Snapshot {
        let nothingRunning = !engineStreaming && !Self.anyCameraRunning()
        let (loading, foreign, candidateIDs, started, error) = lock.withLock {
            if nothingRunning { replay.reconcileNothingRunning() }
            let clients = replay.clients
            return (!replay.historyLoaded, clients.foreignStreams(own: engineStreaming ? 1 : 0),
                    clients.candidates(excluding: getpid()), clients.startedStream, self.error)
        }
        let candidates = candidateIDs.map {
            Client(pid: $0, name: Self.processName($0), startedStream: started.contains($0))
        }
        return Snapshot(loading: loading, foreignStreams: foreign, candidates: candidates, error: error)
    }

    private func startStream() {
        let live = Process()
        live.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        live.arguments = ["stream", "--style", "ndjson", "--info", "--predicate", Self.predicate]
        let pipe = Pipe()
        live.standardOutput = pipe
        live.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF: without clearing the handler, Foundation keeps calling it with empty data.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.lock.withLock { self?.replay.ingestLive(data) }
        }
        live.terminationHandler = { [weak self] process in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            self.lock.withLock { self.error = "log stream exited (\(process.terminationStatus)); restarting" }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.restartDelay) { self.startStream() }
        }
        do {
            try live.run()
            let keep = lock.withLock {
                guard !stopped else { return false }
                stream = live
                error = nil
                return true
            }
            if !keep { live.terminate() }
        } catch {
            lock.withLock { self.error = "cannot start log stream: \(error)" }
        }
    }

    private func loadHistory() {
        let show = Process()
        show.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        show.arguments = ["show", "--last", Self.history, "--info", "--style", "ndjson", "--predicate", Self.predicate]
        let out = Pipe()
        show.standardOutput = out
        show.standardError = FileHandle.nullDevice
        var data: Data?
        var failure: String?
        do {
            try show.run()
            let timeout = DispatchWorkItem { show.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.historyTimeout, execute: timeout)
            let output = out.fileHandleForReading.readDataToEndOfFile()
            show.waitUntilExit()
            timeout.cancel()
            if show.terminationStatus == 0 {
                data = output
            } else {
                failure = "log history unavailable (exit \(show.terminationStatus))"
            }
        } catch {
            failure = "cannot read log history: \(error)"
        }
        lock.withLock {
            replay.ingestHistory(data)
            if let failure { self.error = failure }
        }
    }

    private static func processName(_ pid: Int32) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// CoreMediaIO's DeviceIsRunningSomewhere over all devices: true if any process streams
    /// any camera. Public API, but only a yes/no without the process.
    static func anyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0
        else { return true }
        var ids = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, &ids) == 0
        else { return true }
        return ids.contains { id in
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            // Unknown counts as running, so a failed query never erases stream counts.
            guard CMIOObjectGetPropertyData(id, &running, 0, nil, valueSize, &valueSize, &value) == 0 else { return true }
            return value != 0
        }
    }
}
