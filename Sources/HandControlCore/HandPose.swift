import Foundation

/// Image-space point with x pre-multiplied by the frame aspect ratio, so that
/// distances are isotropic (Vision normalizes both axes to 0...1).
public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 21 joints in MediaPipe order: 0 wrist, 1-4 thumb (CMC→tip), 5-8 index (MCP→tip),
/// 9-12 middle, 13-16 ring, 17-20 little. Stored samples depend on this order.
public enum HandJoint {
    public static let count = 21
    public static let wrist = 0
    public static let middleMCP = 9
}

public enum Features {
    public static let dimension = (HandJoint.count - 1) * 2

    /// Translation- and scale-invariant feature vector: joints relative to the wrist,
    /// in units of palm length (wrist→middle MCP). Rotation is deliberately kept:
    /// thumbs-up vs thumbs-down differ mainly by orientation, and the camera is fixed.
    public static func vector(from joints: [Point]) -> [Double]? {
        guard joints.count == HandJoint.count else { return nil }
        let wrist = joints[HandJoint.wrist]
        let mcp = joints[HandJoint.middleMCP]
        let palm = hypot(mcp.x - wrist.x, mcp.y - wrist.y)
        guard palm > 1e-6 else { return nil }

        var out: [Double] = []
        out.reserveCapacity(dimension)
        for (i, p) in joints.enumerated() where i != HandJoint.wrist {
            out.append((p.x - wrist.x) / palm)
            out.append((p.y - wrist.y) / palm)
        }
        return out
    }

    /// RMS per-joint displacement, in palm lengths: 0.2 means joints are on average
    /// 0.2 palm lengths apart. Independent of the joint count, so thresholds stay readable.
    public static func distance(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count, "feature dimension mismatch")
        var sum = 0.0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return (sum / Double(a.count / 2)).squareRoot()
    }
}
