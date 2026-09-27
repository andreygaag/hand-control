import Foundation
import Testing
@testable import HandControlCore

/// A synthetic hand: wrist at origin, middle MCP one unit up, other joints spread out.
func hand(offset: Double = 0, scale: Double = 1, curl: Double = 0) -> [Point] {
    (0..<HandJoint.count).map { i in
        let base = i == HandJoint.middleMCP ? Point(x: 0, y: 1)
            : Point(x: Double(i % 5) * 0.3 - 0.6, y: Double(i / 5) * 0.4 - curl * Double(i % 4))
        let p = i == HandJoint.wrist ? Point(x: 0, y: 0) : base
        return Point(x: p.x * scale + offset, y: p.y * scale + offset)
    }
}

@Suite struct FeaturesTests {
    @Test func invariantToTranslationAndScale() throws {
        let a = try #require(Features.vector(from: hand()))
        let b = try #require(Features.vector(from: hand(offset: 5, scale: 3)))
        #expect(a.count == Features.dimension)
        #expect(Features.distance(a, b) < 1e-9)
    }

    @Test func keepsRotation() throws {
        let up = hand()
        let down = up.map { Point(x: -$0.x, y: -$0.y) }
        let a = try #require(Features.vector(from: up))
        let b = try #require(Features.vector(from: down))
        #expect(Features.distance(a, b) > 1)
    }

    @Test func rejectsDegenerateInput() {
        #expect(Features.vector(from: Array(hand().prefix(20))) == nil)
        #expect(Features.vector(from: Array(repeating: Point(x: 1, y: 1), count: 21)) == nil)
    }
}

@Suite struct ClassifierTests {
    let samples: [String: [[Point]]] = [
        "open": (0..<5).map { hand(offset: Double($0), scale: 1 + Double($0) * 0.1) },
        "fist": (0..<5).map { hand(offset: Double($0), curl: 1) },
    ]

    @Test func picksNearestClassAndIsScaleInvariant() throws {
        let c = Classifier(samples: samples, maxDistance: 1)
        let v = try #require(Features.vector(from: hand(offset: 42, scale: 7, curl: 0.95)))
        let r = try #require(c.classify(v))
        #expect(r.label == "fist")
        #expect(r.distance < 1)
    }

    @Test func rejectsBeyondMaxDistance() throws {
        let c = Classifier(samples: samples, maxDistance: 0.1)
        let v = try #require(Features.vector(from: hand(curl: 0.5)))
        let r = try #require(c.classify(v))
        #expect(r.label == nil)
        #expect(r.distance > 0.1)
    }

    @Test func majorityVoteBeatsSingleNearOutlier() throws {
        // One "noise" sample sits exactly on the query, but k=3 has two "fist" votes.
        let query = hand(curl: 0.9)
        let c = Classifier(
            samples: ["noise": [query], "fist": [hand(curl: 0.95), hand(curl: 0.85)]],
            k: 3, maxDistance: 10)
        let v = try #require(Features.vector(from: query))
        #expect(c.classify(v)?.label == "fist")
    }

    // Regression (Codex review): far neighbours must not outvote a close one.
    @Test func farNeighboursDoNotVote() throws {
        let query = hand(curl: 0.9)
        let c = Classifier(
            samples: [
                "close": [query, hand(curl: 0.91)],
                "far": [hand(curl: 0.5), hand(curl: 0), hand(curl: -1)],
            ],
            k: 5, maxDistance: 0.05)
        let v = try #require(Features.vector(from: query))
        let r = try #require(c.classify(v))
        #expect(r.label == "close")
        #expect(r.distance == 0)
    }

    @Test func distanceIsRMSPerJointInPalmLengths() throws {
        // 19 of 20 joints displaced by 0.3 palm lengths (wrist and middle MCP fixed, so the
        // palm length is unchanged) → RMS = 0.3 * sqrt(19/20).
        let a = hand()
        let fixed = [HandJoint.wrist, HandJoint.middleMCP]
        let b = a.enumerated().map { i, p in fixed.contains(i) ? p : Point(x: p.x + 0.3, y: p.y) }
        let va = try #require(Features.vector(from: a))
        let vb = try #require(Features.vector(from: b))
        #expect(abs(Features.distance(va, vb) - 0.3 * (19.0 / 20).squareRoot()) < 1e-9)
    }

    @Test func emptyClassifier() {
        let c = Classifier(samples: [:], maxDistance: 1)
        #expect(c.isEmpty)
        #expect(c.classify(Array(repeating: 0, count: Features.dimension)) == nil)
    }

    @Test func separationReportsClosestOtherClass() throws {
        let sep = Classifier(samples: samples, maxDistance: 1).separation()
        let open = try #require(sep["open"])
        #expect(open > 0)
        #expect(sep["fist"] == open)
    }
}
