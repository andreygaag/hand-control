# Architecture

Hand gestures seen by the Mac camera trigger actions (for now: synthetic hotkeys).

## Pipeline

```
AVCaptureSession (640x480, capture fixed at 15 fps; FrameRateGovernor throttles)   HandTracker.swift
 │   15 fps to Vision; 2 fps after max(3 s, release + 1 s) without a hand; back to 15 on any hand frame
 └─ VNDetectHumanHandPoseRequest → 21 joints, MediaPipe order, x scaled by aspect
     └─ Features.vector: relative to wrist, / palm length    HandPose.swift
         └─ Classifier.classify: kNN (k=5) + maxDistance reject   Classifier.swift
             └─ Debouncer.update(Observation): hold → fire once → latch until released   Debouncer.swift
                 └─ config.bindings[label] → Action               Config.swift
                     └─ ActionPerformer.perform → CGEvent post (HID tap) | /usr/bin/pmset   ActionPerformer.swift
```

`record` shares the pipeline up to raw joints and appends them to `gestures.json`.

Menu bar app:

```
HandControlApp (SwiftUI MenuBarExtra, LSUIElement)         HandControlApp.swift
 ├─ Engine actor: start (single-flight) / pause / resume / reload → HandTracker + Runner   Engine.swift
 │    └─ status (state, camera, last fire, bindings, permission, reload error)
 │         → DispatchQueue.main (FIFO) → AppModel → menu + icon
 └─ CameraMonitor: `log stream` of *camerad, then `log show --last 1h` in the background   CameraMonitor.swift
      └─ CameraLogReplay (dedupe by machTimestamp+message) → CameraClients   CameraLogReplay.swift
           └─ snapshot every 3 s (never waits for history) → "other camera readers"
```

## Boundaries

- `HandControlCore` — pure logic (features, kNN, debouncer, key parsing, config, storage, camera-daemon
  log parsing and history/live merging). No camera, no event posting; fully unit-tested.
- `HandControlEngine` — OS integration shared by CLI and app: AVFoundation, Vision, CGEvent, pmset,
  TCC checks, instance lock, event log, `log` subprocesses for camera readers. Only the lock and
  paths are unit-tested (`HandControlEngineTests`).
- `hand-control` executable — CLI (record, run, list, delete, cameras, camera-readers).
- `HandControlApp` executable — menu bar UI only; packaged as HandControl.app by
  `scripts/build-app.sh` with `Support/App-Info.plist`.

## State and invariants

- `gestures.json` stores raw joints, not feature vectors, so normalization can change without
  re-recording. `version` must be bumped if the joint order or coordinate convention changes.
- Joint order is MediaPipe's (`HandJoint`); `HandTracker.jointOrder` must match it.
- Rotation is normalized (palm axis rotated to point up): the hand's angle drifts with posture
  between sessions, and keeping it made held poses miss by d≈0.6 (≈40° tilt). Poses that differ
  only by orientation (thumbs up vs down) are therefore indistinguishable.
- Tracker output is three-way: hand / absent / unreliable. Only an observed pose or observed absence
  moves the debouncer; unreliable frames are skipped. A gap between reliable observations of at most
  `maxGap` is interpolated (the prior state is assumed to continue); a longer gap breaks hold and
  release continuity. Absence releases because lowering the hand is how a gesture ends.
- Only kNN neighbours within `maxDistance` vote, so far samples cannot outvote a close one.
- Any recorded label votes in kNN; a label without a binding acts as a reject class (e.g. "none").
- `system` actions are a closed list (`SystemCommand`), never a free-form shell command.
- `Action` is a closed enum; adding an effect type means a new case and a new branch in `ActionPerformer`.
- Idle frames (0.5 s apart) exceed the debouncer's `maxGap` (0.25 s), so each restarts the release
  timer. Idling therefore waits until release has completed at the active rate
  (`idleAfter >= releaseMs + 1 s`); otherwise a latched pose would never release while idle.
- Camera frame durations must be set after `startRunning()`; set before, they are silently reset.
- Camera callbacks, classification, debouncing and action dispatch all run on the tracker's serial queue.
  The Engine actor serializes control calls; config reload swaps the Runner on the tracker queue.
- One engine per data dir: `run.lock` (flock, O_CLOEXEC, released by the kernel on exit) stops CLI
  `run`, the app and `record` from running together (double actions; actions firing while a gesture
  is recorded). The engine takes it only after config, gestures and permissions check out, so an
  engine stuck in `.failed` does not block the other front end.
- `Engine.start` is single-flight: the actor is re-entrant across `await requestAccess()`, and a
  second start (e.g. Reload during the camera prompt) would otherwise create a second tracker.
- Capture failure (session runtime error, camera disconnected) drops the tracker and sets `.failed`;
  Reload then starts a fresh one. `resume` restarts at full rate (the governor resets on start);
  `reload` also replaces the governor, since `idleAfter` depends on `releaseMs`.
- Pause stops the capture session, so the camera is released (green light off), not just ignored.

## Camera readers (best effort)

No public API names the processes using the camera. AVFoundation's `isInUseByAnotherApplication`
stayed false with a second client; CoreMediaIO's `DeviceIsRunningSomewhere` is a yes/no including us.
`CameraMonitor` therefore reads undocumented `appleh13camerad` log messages (verified: FaceTime HD,
macOS 26; other cameras go through other daemons and are not covered):

- stream count = `added attribution` − `Removed attribution`. Not start/stop streaming lines: a
  client killed mid-stream logs no stop, but its attribution is removed on disconnect.
- candidates = `ConnectClient`/`DisconnectClient [pid]` (connect happens on mere discovery, so
  "connected" is not "reading"), ordered by the Info-level TCC request that marks a first stream start.
- CMIO "nothing running" while we are not streaming resets the count, clearing stale history.
- History covers the last hour: streams and connections older than that are invisible until they
  restart (the menu then says "owner unknown"). The TCC "started a stream" mark exists only in the
  live stream, never in history, so processes that started before launch are never marked.
- `log show` and `log stream` overlap; entries are deduplicated by (machTimestamp, message), which
  is identical for the same entry in both (checked) and immune to UTC-offset changes.
- The predicate matches any `*camerad`; messages of other camera daemons are unverified.

The pid is redacted in stream lines, so the menu shows how many foreign streams exist and which
processes could own them, not an exact owner.

## Observability

`event()` in HandControlEngine/Support.swift writes significant events to stderr and to
`~/Library/Logs/hand-control.log` (`$HAND_CONTROL_DIR/hand-control.log` when set): start (with
bindings), fires (label, distance, action), "no gesture" (a hand shown ≥ 5 frames that fired
nothing and never came within maxDistance, with the closest label and distance — the only trace
of a miss without --debug), idle/active switches, pause/resume/reload, recorded and
deleted gestures, errors, and session end (CLI: SIGINT/SIGTERM; app: quit from the menu). Per-frame
output (`--debug`) goes to stderr only. The log is not rotated; its volume is a few lines per gesture.

## Deterministic vs heuristic

Everything is deterministic code. Tunable heuristics live in `config.json`: `holdMs`, `releaseMs`,
`maxDistance`. `run --debug` prints the per-frame candidate and distance used to tune them.
