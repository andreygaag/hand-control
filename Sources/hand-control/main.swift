import Foundation
import HandControlCore

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Significant events (start/stop, fires, mode changes, errors) go to stderr and to
/// `eventLogURL`; per-frame chatter goes to stderr only. Each line is one O_APPEND write,
/// so lines from different threads do not interleave. No rotation: volume is a few lines
/// per gesture.
private let eventTimestamp = Date.ISO8601FormatStyle(
    dateTimeSeparator: .space, includingFractionalSeconds: true, timeZone: .current)

func event(_ message: String) {
    log(message)
    let line = "\(Date().formatted(eventTimestamp)) \(message)\n"
    let fd = open(eventLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
}

let usage = """
usage:
  hand-control record <gesture> [--samples N] [--camera NAME]
  hand-control run [--debug] [--camera NAME]
  hand-control list
  hand-control delete <gesture>
  hand-control cameras

data dir: $HAND_CONTROL_DIR or ~/.config/hand-control
  gestures.json  recorded samples (written by `record`)
  config.json    bindings and tuning, e.g. {"bindings": {"fist": {"hotkey": "ctrl+right"}}}
event log: ~/Library/Logs/hand-control.log ($HAND_CONTROL_DIR/hand-control.log if set)
"""

let dataDir = ProcessInfo.processInfo.environment["HAND_CONTROL_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hand-control")
let gesturesURL = dataDir.appendingPathComponent("gestures.json")
let configURL = dataDir.appendingPathComponent("config.json")
// ~/Library/Logs is where Console.app looks; an explicit data dir keeps test runs isolated.
let eventLogURL = ProcessInfo.processInfo.environment["HAND_CONTROL_DIR"] != nil
    ? dataDir.appendingPathComponent("hand-control.log")
    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/hand-control.log")

/// Frames per second fed to Vision; the camera runs faster, extra frames are dropped.
let trackingFPS = 15.0
/// Rate after `idleAfter` without a hand. Its interval (0.2 s) must stay below
/// `maxObservationGap`, or idle absence frames would break release continuity.
let idleFPS = 5.0
let idleAfter: TimeInterval = 3
/// Unobserved time after which a hold or release loses continuity (~3 frames at 15 fps).
let maxObservationGap: TimeInterval = 0.25
/// Minimum spacing between recorded samples: consecutive frames are near-duplicates.
let recordInterval: TimeInterval = 0.2

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: ArraySlice<String>, valued: Set<String>) throws {
        var it = raw.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valued.contains(name) {
                    guard let v = it.next() else { throw CLIError("--\(name) needs a value") }
                    options[name] = v
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(a)
            }
        }
    }
}

func loadConfig() throws -> Config {
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        try Config().save(to: configURL)
        log("created \(configURL.path)")
        return Config()
    }
    return try Config.load(from: configURL)
}

func startTracking(camera: String?, governor: FrameRateGovernor,
                   onFrame: @escaping HandTracker.FrameHandler) async throws -> HandTracker {
    guard await HandTracker.requestAccess() else {
        throw CLIError("no camera access: System Settings → Privacy & Security → Camera, enable your terminal")
    }
    let tracker = try HandTracker(cameraName: camera, governor: governor, onFrame: onFrame)
    tracker.start()
    return tracker
}

/// Keeps the process and the tracker alive until a frame callback or Ctrl-C calls exit().
/// Not dispatchMain(): async top-level code already drains the main queue, and calling
/// dispatchMain() from here traps.
/// Logs "stopped" on Ctrl-C / kill before exiting, so the event log shows session bounds.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
func stopOnSignals() {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            event("stopped (\(sig == SIGINT ? "SIGINT" : "SIGTERM"))")
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

func parkForever(_ tracker: HandTracker) async throws -> Never {
    while true {
        try await Task.sleep(for: .seconds(3600))
        extendLifetime(tracker)
    }
}

/// State confined to the tracker's queue (see HandTracker).
final class Recording: @unchecked Sendable {
    var store: GestureStore
    var taken = 0
    var lastTaken = -TimeInterval.infinity
    init(store: GestureStore) { self.store = store }
}

func record(_ args: Args) async throws -> Never {
    guard args.positional.count == 1, let name = args.positional.first else { throw CLIError(usage) }
    let target = Int(args.options["samples"] ?? "30") ?? 0
    guard target > 0 else { throw CLIError("--samples must be a positive integer") }
    _ = try loadConfig()
    let rec = Recording(store: try GestureStore.load(from: gesturesURL))

    for n in (1...3).reversed() {
        log("show '\(name)' in \(n)…")
        try await Task.sleep(for: .seconds(1))
    }
    log("recording — move and tilt the hand slightly for variety")

    // No idle mode while recording: the user is about to show the hand.
    let governor = FrameRateGovernor(activeFPS: trackingFPS, idleFPS: trackingFPS, idleAfter: .infinity)
    let tracker = try await startTracking(camera: args.options["camera"], governor: governor) { detection, time in
        guard case .hand(let joints) = detection else { return }
        guard time - rec.lastTaken >= recordInterval else { return }
        rec.lastTaken = time
        rec.store.samples[name, default: []].append(joints)
        rec.taken += 1
        log("  \(rec.taken)/\(target)")
        guard rec.taken == target else { return }
        do {
            try rec.store.save(to: gesturesURL)
            event("recorded '\(name)': \(rec.store.samples[name]!.count) samples total")
            exit(0)
        } catch {
            event("error: \(error)")
            exit(1)
        }
    }
    try await parkForever(tracker)
}

final class Runner: @unchecked Sendable {
    let classifier: Classifier
    let config: Config
    let debug: Bool
    let performer = ActionPerformer()
    var debouncer: Debouncer
    var lastDistance: Double?

    init(classifier: Classifier, config: Config, debug: Bool) {
        self.classifier = classifier
        self.config = config
        self.debug = debug
        debouncer = Debouncer(
            hold: Double(config.holdMs) / 1000,
            release: Double(config.releaseMs) / 1000,
            maxGap: maxObservationGap)
    }

    func handle(_ detection: Detection, at time: TimeInterval) {
        let observation: Observation
        switch detection {
        case .absent:
            observation = .absent
            if debug { log("no hand") }
        case .unreliable(let reason):
            observation = .unreliable
            if debug { log("unreliable: \(reason)") }
        case .hand(let joints):
            let result = Features.vector(from: joints).flatMap(classifier.classify)
            observation = result.map { .pose($0.label) } ?? .unreliable
            lastDistance = result?.distance
            if debug {
                log(result.map {
                    String(format: "%@ d=%.3f%@", $0.candidate, $0.distance, $0.label == nil ? " (rejected)" : "")
                } ?? "unreliable: degenerate hand geometry")
            }
        }
        guard let fired = debouncer.update(observation, at: time) else { return }
        guard let action = config.bindings[fired] else {
            if debug { log("→ \(fired): no binding") }
            return
        }
        let distance = lastDistance.map { String(format: " d=%.3f", $0) } ?? ""
        event("fire \(fired)\(distance) → \(action)")
        do {
            try performer.perform(action)
        } catch {
            event("error: \(fired): \(error)")
        }
    }
}

func run(_ args: Args) async throws -> Never {
    let config = try loadConfig()
    let store = try GestureStore.load(from: gesturesURL)
    let classifier = Classifier(samples: store.samples, maxDistance: config.maxDistance)
    guard !classifier.isEmpty else { throw CLIError("no gestures recorded; run `hand-control record <name>`") }
    for label in config.bindings.keys.sorted() where store.samples[label] == nil {
        log("warning: binding '\(label)' has no recorded samples")
    }
    let needsKeyEvents = config.bindings.values.contains { if case .hotkey = $0 { true } else { false } }
    guard !needsKeyEvents || ActionPerformer.ensureAccess() else {
        throw CLIError("no Accessibility access: System Settings → Privacy & Security → Accessibility, enable your terminal, then restart it")
    }

    let runner = Runner(classifier: classifier, config: config, debug: args.flags.contains("debug"))
    let governor = FrameRateGovernor(activeFPS: trackingFPS, idleFPS: idleFPS, idleAfter: idleAfter)
    let tracker = try await startTracking(camera: args.options["camera"], governor: governor, onFrame: runner.handle)
    let bound = config.bindings.keys.sorted().map { "\($0)=\(config.bindings[$0]!)" }
    event("started: \(bound.isEmpty ? "no bindings" : bound.joined(separator: ", ")); maxDistance=\(config.maxDistance)")
    stopOnSignals()
    try await parkForever(tracker)
}

func list() throws {
    let store = try GestureStore.load(from: gesturesURL)
    let config = try loadConfig()
    let separation = Classifier(samples: store.samples, maxDistance: config.maxDistance).separation()
    for label in store.samples.keys.sorted() {
        let binding = config.bindings[label].map { "\($0)" } ?? "unbound"
        let sep = separation[label].map { String(format: "%.3f", $0) } ?? "-"
        print("\(label)\tsamples=\(store.samples[label]!.count)\tnearest-other=\(sep)\t\(binding)")
    }
}

func delete(_ args: Args) throws {
    guard args.positional.count == 1, let name = args.positional.first else { throw CLIError(usage) }
    var store = try GestureStore.load(from: gesturesURL)
    guard store.samples.removeValue(forKey: name) != nil else { throw CLIError("no gesture '\(name)'") }
    try store.save(to: gesturesURL)
    event("deleted '\(name)'")
}

do {
    let argv = CommandLine.arguments
    guard argv.count >= 2 else { throw CLIError(usage) }
    let args = try Args(argv.dropFirst(2), valued: ["samples", "camera"])
    switch argv[1] {
    case "record": try await record(args)
    case "run": try await run(args)
    case "list": try list()
    case "delete": try delete(args)
    case "cameras": HandTracker.cameras().forEach { print($0.localizedName) }
    default: throw CLIError(usage)
    }
} catch let error as CLIError where error.description == usage {
    log(usage)
    exit(1)
} catch {
    event("error: \(error)")
    exit(1)
}
