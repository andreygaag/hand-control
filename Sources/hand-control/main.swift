import Foundation
import HandControlCore
import HandControlEngine

let usage = """
usage:
  hand-control record <gesture> [--samples N] [--camera NAME]
  hand-control run [--debug] [--camera NAME]
  hand-control list
  hand-control delete <gesture>
  hand-control cameras
  hand-control camera-readers    other camera streams and their possible owners (best effort,
                                 from the system log; counts a running Hand Control app too)

data dir: $HAND_CONTROL_DIR or ~/.config/hand-control
  gestures.json  recorded samples (written by `record`)
  config.json    bindings and tuning, e.g. {"bindings": {"fist": {"hotkey": "ctrl+right"}}}
event log: ~/Library/Logs/hand-control.log ($HAND_CONTROL_DIR/hand-control.log if set)
"""

let paths = Paths.current

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
                    guard let v = it.next() else { throw HandControlError("--\(name) needs a value") }
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

/// Keeps the process and `owner` alive until a callback or Ctrl-C calls exit().
/// Not dispatchMain(): async top-level code already drains the main queue, and calling
/// dispatchMain() from here traps.
func parkForever(_ owner: AnyObject) async throws -> Never {
    while true {
        try await Task.sleep(for: .seconds(3600))
        extendLifetime(owner)
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
    guard args.positional.count == 1, let name = args.positional.first else { throw HandControlError(usage) }
    let target = Int(args.options["samples"] ?? "30") ?? 0
    guard target > 0 else { throw HandControlError("--samples must be a positive integer") }
    // Without the lock a running app or `run` would fire actions while the gesture is shown.
    let lock = try InstanceLock(at: paths.lock)
    _ = try Engine.loadConfig(at: paths.config)
    let rec = Recording(store: try GestureStore.load(from: paths.gestures))
    guard await HandTracker.requestAccess() else {
        throw HandControlError("no camera access: System Settings → Privacy & Security → Camera")
    }

    for n in (1...3).reversed() {
        log("show '\(name)' in \(n)…")
        try await Task.sleep(for: .seconds(1))
    }
    log("recording — move and tilt the hand slightly for variety")

    // No idle mode while recording: the user is about to show the hand.
    let governor = FrameRateGovernor(activeFPS: Tuning.trackingFPS, idleFPS: Tuning.trackingFPS, idleAfter: .infinity)
    let tracker = try HandTracker(cameraName: args.options["camera"], governor: governor) { detection, time in
        guard case .hand(let joints) = detection else { return }
        guard time - rec.lastTaken >= Tuning.recordInterval else { return }
        rec.lastTaken = time
        rec.store.samples[name, default: []].append(joints)
        rec.taken += 1
        log("  \(rec.taken)/\(target)")
        guard rec.taken == target else { return }
        do {
            try rec.store.save(to: paths.gestures)
            event("recorded '\(name)': \(rec.store.samples[name]!.count) samples total")
            exit(0)
        } catch {
            event("error: \(error)")
            exit(1)
        }
    }
    tracker.start()
    extendLifetime(lock)
    try await parkForever(tracker)
}

func run(_ args: Args) async -> Never {
    let engine = Engine(cameraName: args.options["camera"], debug: args.flags.contains("debug"))
    do {
        try await engine.start()
    } catch {
        exit(1) // Engine.start already reported it (event log and stderr).
    }
    stopOnSignals()
    try? await parkForever(engine)
    exit(0)
}

func list() throws {
    let store = try GestureStore.load(from: paths.gestures)
    let config = try Engine.loadConfig(at: paths.config)
    let separation = Classifier(samples: store.samples, maxDistance: config.maxDistance).separation()
    for label in store.samples.keys.sorted() {
        let binding = config.bindings[label].map { "\($0)" } ?? "unbound"
        let sep = separation[label].map { String(format: "%.3f", $0) } ?? "-"
        print("\(label)\tsamples=\(store.samples[label]!.count)\tnearest-other=\(sep)\t\(binding)")
    }
}

func cameraReaders() async throws {
    let monitor = CameraMonitor()
    monitor.start()
    // History replay takes a few seconds; the monitor bounds it with its own timeout.
    var snapshot = monitor.snapshot(engineStreaming: false)
    while snapshot.loading {
        try await Task.sleep(for: .milliseconds(200))
        snapshot = monitor.snapshot(engineStreaming: false)
    }
    monitor.stop()
    if let error = snapshot.error { throw HandControlError("camera monitor: \(error)") }
    print("other camera streams: \(snapshot.foreignStreams)")
    for client in snapshot.candidates {
        print("  \(client.name) (pid \(client.pid))\(client.startedStream ? " — started a stream" : "")")
    }
}

func delete(_ args: Args) throws {
    guard args.positional.count == 1, let name = args.positional.first else { throw HandControlError(usage) }
    var store = try GestureStore.load(from: paths.gestures)
    guard store.samples.removeValue(forKey: name) != nil else { throw HandControlError("no gesture '\(name)'") }
    try store.save(to: paths.gestures)
    event("deleted '\(name)'")
}

let argv = CommandLine.arguments
let args: Args
do {
    guard argv.count >= 2 else { throw HandControlError(usage) }
    args = try Args(argv.dropFirst(2), valued: ["samples", "camera"])
} catch {
    // Usage mistakes go to the terminal only, not to the event log.
    log("\(error)")
    exit(1)
}

do {
    switch argv[1] {
    case "record": try await record(args)
    case "run": await run(args)
    case "list": try list()
    case "delete": try delete(args)
    case "cameras": HandTracker.cameras().forEach { print($0.localizedName) }
    case "camera-readers": try await cameraReaders()
    default: throw HandControlError(usage)
    }
} catch let error as HandControlError where error.description == usage {
    log(usage)
    exit(1)
} catch {
    event("error: \(error)")
    exit(1)
}
