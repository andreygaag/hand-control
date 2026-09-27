import Foundation
import Testing
@testable import HandControlCore

@Suite struct CameraLogReplayTests {
    /// One ndjson line as `log show/stream --style ndjson` prints it (fields trimmed).
    func line(_ mach: UInt64, _ message: String) -> String {
        let object: [String: Any] = ["machTimestamp": mach, "eventMessage": message,
                                     "timestamp": "2026-09-27 20:30:22.131743+0300"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    func data(_ lines: String...) -> Data { Data(lines.joined().utf8) }

    @Test func entryInBothHistoryAndLiveCountsOnce() {
        var r = CameraLogReplay()
        r.ingestLive(data(line(10, DaemonLine.addAttribution)))
        r.ingestHistory(data(line(10, DaemonLine.addAttribution)))
        #expect(r.clients.activeStreams == 1)
    }

    @Test func liveAfterHistoryIsApplied() {
        var r = CameraLogReplay()
        r.ingestHistory(data(line(10, DaemonLine.addAttribution)))
        r.ingestLive(data(line(20, DaemonLine.addAttribution)))
        #expect(r.clients.activeStreams == 2)
    }

    // Info-level lines are live-only; an older timestamp than history's last entry must not
    // drop them (a time watermark would).
    @Test func liveOnlyEntryOlderThanHistoryIsKept() {
        var r = CameraLogReplay()
        r.ingestLive(data(line(5, DaemonLine.tcc)))
        r.ingestHistory(data(line(10, DaemonLine.connect)))
        #expect(r.clients.startedStream == [89067])
        #expect(r.clients.connected == [81510])
    }

    @Test func lineSplitAcrossChunksIsAppliedOnce() {
        var r = CameraLogReplay()
        r.ingestHistory(nil)
        let whole = Data(line(10, DaemonLine.addAttribution).utf8)
        r.ingestLive(whole.prefix(37))
        #expect(r.clients.activeStreams == 0)
        r.ingestLive(whole.dropFirst(37))
        #expect(r.clients.activeStreams == 1)
    }

    @Test func liveIsBufferedUntilHistory() {
        var r = CameraLogReplay()
        r.ingestLive(data(line(10, DaemonLine.addAttribution)))
        #expect(!r.historyLoaded)
        #expect(r.clients.activeStreams == 0)
        r.ingestHistory(nil)
        #expect(r.historyLoaded)
        #expect(r.clients.activeStreams == 1)
    }

    @Test func junkIsIgnored() {
        var r = CameraLogReplay()
        r.ingestHistory(data(
            "Filtering the log data using \"process ENDSWITH camerad\"\n",
            "{\"count\":42,\"finished\":1}\n",
            "{\"eventMessage\":\"\(DaemonLine.connect)\"}\n",        // no machTimestamp
            "{\"machTimestamp\":7}\n",                                 // no message
            line(11, DaemonLine.startInternal)))                       // real but irrelevant
        #expect(r.clients == CameraClients())
    }
}
