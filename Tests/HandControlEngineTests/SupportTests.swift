import Foundation
import Testing
@testable import HandControlEngine

@Suite struct InstanceLockTests {
    func tempLock() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested/run.lock")
    }

    // flock locks belong to the open file description, so a second open in the same
    // process conflicts just like another process would.
    @Test func secondHolderIsRefusedWithOwnerPid() throws {
        let url = tempLock()
        let first = try InstanceLock(at: url)
        let error = #expect(throws: HandControlError.self) { try InstanceLock(at: url) }
        #expect(error?.description.contains("pid \(getpid())") == true)
        extendLifetime(first)
    }

    @Test func releasedLockCanBeTakenAgain() throws {
        let url = tempLock()
        do { _ = try InstanceLock(at: url) }
        _ = try InstanceLock(at: url)
    }

    @Test func createsMissingDirectories() throws {
        let url = tempLock()
        _ = try InstanceLock(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct PathsTests {
    @Test func overrideKeepsEverythingInOneDir() {
        let p = Paths(environment: ["HAND_CONTROL_DIR": "/tmp/hc-test"])
        #expect(p.config.path == "/tmp/hc-test/config.json")
        #expect(p.gestures.path == "/tmp/hc-test/gestures.json")
        #expect(p.lock.path == "/tmp/hc-test/run.lock")
        #expect(p.eventLog.path == "/tmp/hc-test/hand-control.log")
    }

    @Test func defaultLogsToLibraryLogs() {
        let p = Paths(environment: [:])
        #expect(p.eventLog.path.hasSuffix("/Library/Logs/hand-control.log"))
        #expect(p.config.path.hasSuffix("/.config/hand-control/config.json"))
    }
}
