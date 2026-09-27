import Foundation
import HandControlCore

public enum Permission: Sendable {
    case camera, accessibility
}

public struct EngineStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case starting, active, idle, paused
        case failed(String)
    }

    public struct Fire: Equatable, Sendable {
        public let label: String
        public let action: String
        public let date: Date
    }

    public var state: State = .starting
    public var camera: String?
    public var lastFire: Fire?
    /// "label → action", sorted by label.
    public var bindings: [String] = []
    /// Set when `.failed` was caused by a missing permission, to offer the right settings pane.
    public var missingPermission: Permission?
    /// A reload that failed while the engine kept running with the previous config.
    public var reloadError: String?

    public init() {}

    /// True while the engine holds the camera streaming.
    public var isStreaming: Bool { state == .active || state == .idle }
}

private struct PermissionError: Error, CustomStringConvertible {
    let permission: Permission
    let description: String
}

/// Camera → gestures → actions, with start / pause / resume / reload.
///
/// The actor serializes control calls; `start` is additionally single-flight, because the
/// actor is re-entrant across its `await`s. Frames are handled on the tracker's queue, which
/// owns the Runner; reloads swap the Runner and governor on that queue. Status changes are
/// pushed to `onStatus` from the actor, in order.
public actor Engine {
    private let cameraName: String?
    private let debug: Bool
    private let onStatus: @Sendable (EngineStatus) -> Void

    private var status = EngineStatus()
    private var tracker: HandTracker?
    private var starting: Task<Void, Error>?
    private var lock: InstanceLock?
    private let box = RunnerBox()

    public init(cameraName: String? = nil, debug: Bool = false,
                onStatus: @escaping @Sendable (EngineStatus) -> Void = { _ in }) {
        self.cameraName = cameraName
        self.debug = debug
        self.onStatus = onStatus
    }

    /// Loads config and gestures, checks permissions, opens the camera. On failure the
    /// status becomes `.failed` with a user-facing message, and the error is rethrown.
    /// Concurrent calls share one attempt.
    public func start() async throws {
        if tracker != nil { return }
        if let starting { return try await starting.value }
        let attempt = Task { try await self.startOnce() }
        starting = attempt
        defer { starting = nil }
        try await attempt.value
    }

    private func startOnce() async throws {
        update { $0.state = .starting; $0.missingPermission = nil; $0.reloadError = nil }
        do {
            let (runner, config) = try makeRunner()
            guard await HandTracker.requestAccess() else {
                throw PermissionError(permission: .camera, description:
                    "no camera access: System Settings → Privacy & Security → Camera")
            }
            // Taken only once everything else checks out, so an engine stuck in .failed does
            // not block the other front end (CLI or app).
            if lock == nil { lock = try InstanceLock(at: Paths.current.lock) }
            box.runner = runner
            let box = self.box
            let tracker = try HandTracker(
                cameraName: cameraName, governor: Self.governor(for: config),
                onModeChange: { [weak self] _ in Task { await self?.syncMode() } },
                onFailure: { [weak self] reason in Task { await self?.cameraFailed(reason) } },
                onFrame: { detection, time in box.runner?.handle(detection, at: time) })
            let fps = tracker.start()
            self.tracker = tracker
            update {
                $0.state = .active
                $0.camera = "\(tracker.cameraName), \(Int(fps)) fps"
                $0.bindings = Self.menuLines(config)
            }
            event("started: \(Self.summary(config))")
        } catch {
            update {
                $0.state = .failed("\(error)")
                $0.missingPermission = (error as? PermissionError)?.permission
            }
            event("error: \(error)")
            throw error
        }
    }

    /// Stops capture and releases the camera.
    public func pause() {
        guard let tracker, status.isStreaming else { return }
        tracker.stop()
        update { $0.state = .paused }
        event("paused")
    }

    /// Restarts capture at full rate (the tracker resets its idle state on start).
    public func resume() {
        guard let tracker, status.state == .paused else { return }
        tracker.start()
        update { $0.state = .active }
        event("resumed")
    }

    /// Re-reads config.json and gestures.json. If the engine is not running (never started,
    /// failed, camera lost), this is a start attempt — e.g. after granting a permission.
    /// A failed reload keeps the running engine on its previous config and sets `reloadError`.
    public func reload() async throws {
        guard let tracker else { return try await start() }
        do {
            let (runner, config) = try makeRunner()
            let box = self.box
            tracker.onQueue { box.runner = runner }
            // idleAfter depends on releaseMs; see Tuning.minIdleAfter.
            tracker.replaceGovernor(Self.governor(for: config))
            update { $0.bindings = Self.menuLines(config); $0.reloadError = nil }
            event("reloaded: \(Self.summary(config))")
        } catch {
            update { $0.reloadError = "\(error)" }
            event("error: reload: \(error)")
            throw error
        }
    }

    private func makeRunner() throws -> (Runner, Config) {
        let config = try Self.loadConfig(at: Paths.current.config)
        let store = try GestureStore.load(from: Paths.current.gestures)
        let classifier = Classifier(samples: store.samples, maxDistance: config.maxDistance)
        guard !classifier.isEmpty else {
            throw HandControlError("no gestures recorded; run `hand-control record <name>`")
        }
        for label in config.bindings.keys.sorted() where store.samples[label] == nil {
            event("warning: binding '\(label)' has no recorded samples")
        }
        guard !ActionPerformer.needsKeyEvents(config) || ActionPerformer.ensureAccess() else {
            // Whether macOS reports a fresh grant to a running process is unverified, hence
            // "or restart".
            throw PermissionError(permission: .accessibility, description:
                "no Accessibility access: System Settings → Privacy & Security → Accessibility, enable the app running hand-control, then reload or restart it")
        }
        let runner = Runner(classifier: classifier, config: config, debug: debug) { [weak self] fire in
            Task { await self?.fired(fire) }
        }
        return (runner, config)
    }

    /// Creates a default config on first use.
    public static func loadConfig(at url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try Config().save(to: url)
            event("created \(url.path)")
            return Config()
        }
        return try Config.load(from: url)
    }

    private static func governor(for config: Config) -> FrameRateGovernor {
        let idleAfter = max(Tuning.minIdleAfter, Double(config.releaseMs) / 1000 + 1)
        return FrameRateGovernor(activeFPS: Tuning.trackingFPS, idleFPS: Tuning.idleFPS, idleAfter: idleAfter)
    }

    private static func menuLines(_ config: Config) -> [String] {
        config.bindings.keys.sorted().map { "\($0) → \(config.bindings[$0]!)" }
    }

    /// Event-log form, unchanged from earlier versions: "fist=hotkey ctrl+right, …; maxDistance=0.25".
    private static func summary(_ config: Config) -> String {
        let bound = config.bindings.keys.sorted().map { "\($0)=\(config.bindings[$0]!)" }
        return "\(bound.isEmpty ? "no bindings" : bound.joined(separator: ", ")); maxDistance=\(config.maxDistance)"
    }

    /// Mode-change callbacks hop here through separate Tasks, which may run out of order;
    /// reading the tracker's current state makes the order irrelevant.
    private func syncMode() {
        guard let tracker, status.isStreaming else { return }
        let idle = tracker.isIdle
        update { $0.state = idle ? .idle : .active }
    }

    private func fired(_ fire: EngineStatus.Fire) {
        guard fire.date >= status.lastFire?.date ?? .distantPast else { return }
        update { $0.lastFire = fire }
    }

    /// Capture is gone; drop the tracker so that reload() starts a fresh one.
    private func cameraFailed(_ reason: String) {
        guard let tracker else { return }
        tracker.stop()
        self.tracker = nil
        update { $0.state = .failed(reason) }
        event("error: \(reason)")
    }

    private func update(_ change: (inout EngineStatus) -> Void) {
        change(&status)
        onStatus(status)
    }
}

/// Holds the current Runner. @unchecked Sendable: read and written only on the tracker queue
/// (set before the tracker starts, swapped afterwards via HandTracker.onQueue).
private final class RunnerBox: @unchecked Sendable {
    var runner: Runner?
}

/// Per-frame classification and debouncing; runs on the tracker queue only.
final class Runner: @unchecked Sendable {
    private let classifier: Classifier
    private let config: Config
    private let debug: Bool
    private let onFire: (EngineStatus.Fire) -> Void
    private let performer = ActionPerformer()
    private var debouncer: Debouncer
    private var lastDistance: Double?
    private var episode = Episode()

    /// One continuous appearance of the hand, for the "no gesture" event: without it a
    /// shown-but-rejected gesture leaves no trace outside --debug (the app has no --debug).
    private struct Episode {
        var frames = 0
        var fired = false
        var closest: (label: String, distance: Double)?
    }

    /// ~1/3 s at 15 fps: shorter appearances are a hand passing through, not an attempt.
    private static let minEpisodeFrames = 5

    init(classifier: Classifier, config: Config, debug: Bool, onFire: @escaping (EngineStatus.Fire) -> Void) {
        self.classifier = classifier
        self.config = config
        self.debug = debug
        self.onFire = onFire
        debouncer = Debouncer(
            hold: Double(config.holdMs) / 1000,
            release: Double(config.releaseMs) / 1000,
            maxGap: Tuning.maxObservationGap)
    }

    func handle(_ detection: Detection, at time: TimeInterval) {
        let observation: Observation
        switch detection {
        case .absent:
            observation = .absent
            if debug { log("no hand") }
            endEpisode()
        case .unreliable(let reason):
            observation = .unreliable
            if debug { log("unreliable: \(reason)") }
        case .hand(let joints):
            let result = Features.vector(from: joints).flatMap(classifier.classify)
            observation = result.map { .pose($0.label) } ?? .unreliable
            lastDistance = result?.distance
            episode.frames += 1
            if let result, result.distance < episode.closest?.distance ?? .infinity {
                episode.closest = (result.candidate, result.distance)
            }
            if debug {
                log(result.map {
                    String(format: "%@ d=%.3f%@", $0.candidate, $0.distance, $0.label == nil ? " (rejected)" : "")
                } ?? "unreliable: degenerate hand geometry")
            }
        }
        guard let fired = debouncer.update(observation, at: time) else { return }
        guard let action = config.bindings[fired] else {
            episode.fired = true
            if debug { log("→ \(fired): no binding") }
            return
        }
        episode.fired = true
        let distance = lastDistance.map { String(format: " d=%.3f", $0) } ?? ""
        event("fire \(fired)\(distance) → \(action)")
        onFire(EngineStatus.Fire(label: fired, action: "\(action)", date: Date()))
        do {
            try performer.perform(action)
        } catch {
            event("error: \(fired): \(error)")
        }
    }

    private func endEpisode() {
        defer { episode = Episode() }
        // Only a classification miss is reported. A match that did not fire is the debouncer
        // at work (hold not reached, or the previous fire still latched after a brief
        // absence), not something re-recording would fix.
        guard !episode.fired, episode.frames >= Self.minEpisodeFrames, let closest = episode.closest,
              closest.distance > config.maxDistance else { return }
        event(String(format: "no gesture: hand shown %d frames, closest %@ d=%.3f (maxDistance %.2f)",
                     episode.frames, closest.label, closest.distance, config.maxDistance))
    }
}
