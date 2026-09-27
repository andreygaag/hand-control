import Foundation

/// Merges `log show` history and `log stream` live output (ndjson) into CameraClients,
/// counting each log entry once.
///
/// The two sources overlap: live starts before history is read, and history reaches up to
/// the moment `log show` runs. Entries are identified by (machTimestamp, message) — the same
/// entry carries the same pair in both sources — rather than by a time watermark, because
/// Info-level lines are in the live stream but not in the persisted history and must not be
/// dropped just for being older than the last history entry. machTimestamp is also immune to
/// UTC-offset changes that break comparing formatted timestamps.
///
/// Live data arriving before history is ingested is buffered, then applied after history.
public struct CameraLogReplay: Sendable {
    public private(set) var clients = CameraClients()
    public private(set) var historyLoaded = false

    private struct Entry: Hashable, Sendable {
        let mach: UInt64
        let message: String
    }

    /// History entries, kept only while live output can still overlap them: once a live
    /// entry is newer than all of history, the overlap is over and the set is released
    /// (the app runs for days; live entries are never stored).
    private var history: Set<Entry> = []
    private var historyMaxMach: UInt64 = 0
    private var pendingLive: [Entry] = []
    private var partialLine = Data()

    public init() {}

    /// A chunk of `log stream --style ndjson` output; may end mid-line.
    public mutating func ingestLive(_ data: Data) {
        partialLine.append(data)
        while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partialLine[partialLine.startIndex..<newline]
            partialLine = Data(partialLine[partialLine.index(after: newline)...])
            guard let entry = Self.decode(line) else { continue }
            if historyLoaded { applyLive(entry) } else { pendingLive.append(entry) }
        }
    }

    /// Complete `log show --style ndjson` output. Pass nil if history could not be read:
    /// buffered live entries are then applied on their own.
    public mutating func ingestHistory(_ data: Data?) {
        for line in data?.split(separator: UInt8(ascii: "\n")) ?? [] {
            guard let entry = Self.decode(line), history.insert(entry).inserted else { continue }
            historyMaxMach = max(historyMaxMach, entry.mach)
            apply(entry)
        }
        historyLoaded = true
        pendingLive.forEach { applyLive($0) }
        pendingLive = []
    }

    /// See CameraClients.reconcileNothingRunning.
    public mutating func reconcileNothingRunning() {
        clients.reconcileNothingRunning()
    }

    private mutating func applyLive(_ entry: Entry) {
        if entry.mach > historyMaxMach {
            history = []
        } else if history.contains(entry) {
            return
        }
        apply(entry)
    }

    private mutating func apply(_ entry: Entry) {
        if let event = CameraClients.parse(entry.message) { clients.apply(event) }
    }

    /// Non-JSON lines (the "Filtering the log data…" banner), the trailing summary object
    /// and entries without a message or mach timestamp are skipped.
    private static func decode(_ line: some DataProtocol) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let mach = (object["machTimestamp"] as? NSNumber)?.uint64Value
        else { return nil }
        return Entry(mach: mach, message: message)
    }
}
