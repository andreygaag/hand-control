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

## Boundaries

- `HandControlCore` — pure logic (features, kNN, debouncer, key parsing, config, storage). No camera,
  no event posting; fully unit-tested.
- `hand-control` executable — OS integration only: AVFoundation, Vision, CGEvent, TCC, CLI.

## State and invariants

- `gestures.json` stores raw joints, not feature vectors, so normalization can change without
  re-recording. `version` must be bumped if the joint order or coordinate convention changes.
- Joint order is MediaPipe's (`HandJoint`); `HandTracker.jointOrder` must match it.
- Rotation is not normalized: orientation distinguishes poses (thumbs up vs down) and the camera is fixed.
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

## Observability

`event()` in main.swift writes significant events — start (with bindings), fires (label, distance,
action), idle/active switches, recorded/deleted gestures, errors, stop on SIGINT/SIGTERM — to stderr
and to `~/Library/Logs/hand-control.log` (`$HAND_CONTROL_DIR/hand-control.log` when set). Per-frame
output (`--debug`) goes to stderr only. The log is not rotated; its volume is a few lines per gesture.

## Deterministic vs heuristic

Everything is deterministic code. Tunable heuristics live in `config.json`: `holdMs`, `releaseMs`,
`maxDistance`. `run --debug` prints the per-frame candidate and distance used to tune them.
