import Testing
@testable import HandControlCore

@Suite struct DebouncerTests {
    /// Shorthand: a String is a clearly seen pose, "-" is absent, "?" is unreliable.
    func obs(_ s: String) -> Observation {
        switch s {
        case "-": .absent
        case "?": .unreliable
        default: .pose(s)
        }
    }

    /// Feeds frames at 8 fps (a step exact in binary floating point, so boundary
    /// comparisons are deterministic) and returns what fired.
    /// hold = 3 frames, release = 2 frames, maxGap = 2 frames.
    func feed(_ frames: [String]) -> [String] {
        var d = Debouncer(hold: 0.375, release: 0.25, maxGap: 0.25)
        return frames.enumerated().compactMap { d.update(obs($1), at: Double($0) * 0.125) }
    }

    @Test func firesOnceAfterHold() {
        var d = Debouncer(hold: 0.375, release: 0.25, maxGap: 0.25)
        let out = (0..<10).map { d.update(.pose("fist"), at: Double($0) * 0.125) }
        #expect(out.compactMap { $0 } == ["fist"])
        #expect(out[3] == "fist")
    }

    @Test func shortPoseDoesNotFire() {
        #expect(feed(["fist", "fist", "-", "-", "-"]).isEmpty)
    }

    @Test func singleFrameFlickerDoesNotRefire() {
        #expect(feed(["fist", "fist", "fist", "fist", "-", "fist", "fist", "fist", "fist"]) == ["fist"])
    }

    @Test func refiresAfterRelease() {
        #expect(feed(["fist", "fist", "fist", "fist", "-", "-", "-", "fist", "fist", "fist", "fist"])
            == ["fist", "fist"])
    }

    @Test func switchingPosesFiresEach() {
        #expect(feed(["fist", "fist", "fist", "fist", "peace", "peace", "peace", "peace"]) == ["fist", "peace"])
    }

    @Test func rejectedPoseNeverFires() {
        var d = Debouncer(hold: 0.375, release: 0.25, maxGap: 0.25)
        #expect((0..<10).compactMap { d.update(.pose(nil), at: Double($0) * 0.125) }.isEmpty)
    }

    // Regression (Codex review): two frames 10 s apart are not a continuous hold.
    @Test func gapBreaksHold() {
        var d = Debouncer(hold: 0.3, release: 0.15, maxGap: 0.25)
        #expect(d.update(.pose("fist"), at: 0) == nil)
        #expect(d.update(.pose("fist"), at: 10) == nil)
        #expect(d.update(.pose("fist"), at: 10.125) == nil)
        #expect(d.update(.pose("fist"), at: 10.375) == "fist")
    }

    // Regression (Codex review): a tracking dropout under a held pose is not a release.
    @Test func unreliableFramesDoNotRelease() {
        #expect(feed(["fist", "fist", "fist", "fist", "?", "fist", "?", "fist", "fist", "fist", "fist"])
            == ["fist"])
    }

    // Contract: a short dropout inside the release window is bridged as continued absence.
    @Test func shortDropoutInsideReleaseWindowIsBridged() {
        #expect(feed(["fist", "fist", "fist", "fist", "-", "?", "-", "fist", "fist", "fist", "fist"])
            == ["fist", "fist"])
    }

    // Contract: a short dropout inside a hold is bridged as continued pose.
    @Test func unreliableFramesDoNotBreakHoldWithinGap() {
        #expect(feed(["fist", "?", "fist", "?", "fist"]) == ["fist"])
    }

    // Idle mode feeds absence frames farther apart than maxGap. This is safe only once the
    // latch has been released at the active rate (main.swift delays idling past release).
    @Test func idleRateAbsenceAfterReleaseAllowsRefire() {
        var d = Debouncer(hold: 0.375, release: 0.25, maxGap: 0.25)
        var fired: [String] = []
        func step(_ o: Observation, _ t: Double) { if let f = d.update(o, at: t) { fired.append(f) } }
        for i in 0...3 { step(.pose("fist"), Double(i) * 0.125) }        // fires at 0.375
        for i in 4...16 { step(.absent, Double(i) * 0.125) }             // released at active rate
        for t in stride(from: 2.5, through: 5.0, by: 0.5) { step(.absent, t) }  // idle, 2 fps
        for i in 0...3 { step(.pose("fist"), 5.5 + Double(i) * 0.125) }  // wake: gap 0.5 > maxGap
        #expect(fired == ["fist", "fist"])
    }

    // Why idling must wait for release: with only idle-rate frames, the latch never releases.
    @Test func idleRateAbsenceNeverReleasesALatch() {
        var d = Debouncer(hold: 0.375, release: 0.25, maxGap: 0.25)
        var fired: [String] = []
        func step(_ o: Observation, _ t: Double) { if let f = d.update(o, at: t) { fired.append(f) } }
        for i in 0...3 { step(.pose("fist"), Double(i) * 0.125) }
        for t in stride(from: 1.0, through: 3.0, by: 0.5) { step(.absent, t) }
        for i in 0...5 { step(.pose("fist"), 3.5 + Double(i) * 0.125) }
        #expect(fired == ["fist"])
    }

    @Test func longDropoutBreaksHold() {
        #expect(feed(["fist", "fist", "?", "?", "?", "fist", "fist"]).isEmpty)
    }
}
