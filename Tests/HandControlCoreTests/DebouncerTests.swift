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

    @Test func longDropoutBreaksHold() {
        #expect(feed(["fist", "fist", "?", "?", "?", "fist", "fist"]).isEmpty)
    }
}
