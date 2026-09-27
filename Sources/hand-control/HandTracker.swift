import AVFoundation
import HandControlCore
import Vision

enum Detection {
    case hand([Point])
    case absent
    /// Vision failed or returned a hand that cannot be trusted; `reason` is for --debug.
    case unreliable(reason: String)
}

/// Camera → Vision hand pose → 21 joints in MediaPipe order.
///
/// @unchecked Sendable: every mutable field is touched only on `queue`, which is the
/// sample-buffer delegate queue. `onFrame` is also invoked on `queue`.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias FrameHandler = (_ detection: Detection, _ time: TimeInterval) -> Void

    /// Below this whole-hand confidence the frame is unreliable. Uncalibrated.
    private static let minHandConfidence: Float = 0.5

    private static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "hand-control.camera")
    private let request = VNDetectHumanHandPoseRequest()
    private var governor: FrameRateGovernor
    private let onFrame: FrameHandler
    private var lastProcessed = -TimeInterval.infinity

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    init(cameraName: String?, governor: FrameRateGovernor, onFrame: @escaping FrameHandler) throws {
        precondition(Self.jointOrder.count == HandJoint.count)
        self.governor = governor
        self.onFrame = onFrame
        request.maximumHandCount = 1
        super.init()

        let device: AVCaptureDevice?
        if let name = cameraName?.lowercased() {
            device = Self.cameras().first { $0.localizedName.lowercased().contains(name) }
        } else {
            device = AVCaptureDevice.default(for: .video) ?? Self.cameras().first
        }
        guard let device else { throw CLIError("camera not found; see `hand-control cameras`") }

        session.beginConfiguration()
        // Vision cost scales with resolution; 640x480 is plenty for one close hand.
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CLIError("cannot open \(device.localizedName)") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CLIError("cannot attach video output") }
        session.addOutput(output)
        session.commitConfiguration()
        event("camera: \(device.localizedName)")
    }

    func start() { session.startRunning() }
    func stop() { session.stopRunning() }

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        // Throttling happens before Vision, which is where the CPU goes. The camera itself
        // keeps delivering at its native rate; dropping those frames is cheap.
        guard time - lastProcessed >= governor.interval else { return }
        lastProcessed = time
        let detection = detect(sampleBuffer)
        let handPresent = if case .absent = detection { false } else { true }
        if governor.update(handPresent: handPresent, at: time) {
            event(governor.isIdle ? "idle: no hand, tracking at reduced rate" : "active: hand seen")
        }
        onFrame(detection, time)
    }

    private func detect(_ sampleBuffer: CMSampleBuffer) -> Detection {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return .unreliable(reason: "no pixel buffer")
        }
        let aspect = Double(CVPixelBufferGetWidth(pixels)) / Double(CVPixelBufferGetHeight(pixels))
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        } catch {
            return .unreliable(reason: "vision: \(error)")
        }
        guard let hand = request.results?.first else { return .absent }
        guard hand.confidence >= Self.minHandConfidence else {
            return .unreliable(reason: String(format: "hand confidence %.2f", hand.confidence))
        }
        let points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
        do {
            points = try hand.recognizedPoints(.all)
        } catch {
            return .unreliable(reason: "joints: \(error)")
        }

        var joints: [Point] = []
        joints.reserveCapacity(HandJoint.count)
        for name in Self.jointOrder {
            // Zero confidence is treated as "no usable location". Apple does not document
            // how occluded joints (e.g. fingertips in a fist) are reported; if a recorded
            // pose keeps showing up as unreliable here, this filter is the suspect.
            guard let p = points[name] else { return .unreliable(reason: "joint \(name.rawValue.rawValue) missing") }
            guard p.confidence > 0 else { return .unreliable(reason: "joint \(name.rawValue.rawValue) confidence 0") }
            joints.append(Point(x: Double(p.location.x) * aspect, y: Double(p.location.y)))
        }
        return .hand(joints)
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }
}
