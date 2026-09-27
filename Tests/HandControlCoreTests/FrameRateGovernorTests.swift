import Testing
@testable import HandControlCore

@Suite struct FrameRateGovernorTests {
    /// Feeds (handPresent, time) pairs; returns which updates changed idle state.
    /// (#expect cannot call a mutating method, hence the helper.)
    func feed(_ g: inout FrameRateGovernor, _ frames: [(Bool, Double)]) -> [Bool] {
        frames.map { g.update(handPresent: $0.0, at: $0.1) }
    }

    func governor() -> FrameRateGovernor { FrameRateGovernor(activeFPS: 16, idleFPS: 4, idleAfter: 1) }

    @Test func goesIdleAfterContinuousAbsence() {
        var g = governor()
        #expect(feed(&g, [(false, 0), (false, 0.5)]) == [false, false])
        #expect(g.interval == 0.0625)
        #expect(feed(&g, [(false, 1), (false, 1.25)]) == [true, false])
        #expect(g.isIdle)
        #expect(g.interval == 0.25)
    }

    @Test func handResetsAbsenceTimer() {
        var g = governor()
        #expect(feed(&g, [(false, 0), (true, 0.75), (false, 1)]) == [false, false, false])
        #expect(!g.isIdle)
        #expect(feed(&g, [(false, 2)]) == [true])
    }

    @Test func handWakesImmediately() {
        var g = governor()
        #expect(feed(&g, [(false, 0), (false, 1), (true, 1.25), (true, 1.3)]) == [false, true, true, false])
        #expect(!g.isIdle)
    }

    @Test func infiniteIdleAfterNeverIdles() {
        var g = FrameRateGovernor(activeFPS: 15, idleFPS: 15, idleAfter: .infinity)
        #expect(feed(&g, [(false, 0), (false, 1e9)]) == [false, false])
    }
}
