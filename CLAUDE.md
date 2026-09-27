# hand-control

Swift package, macOS 14+. Apple Vision hand pose → kNN gestures → hotkeys. See ARCHITECTURE.md.

## Commands

- Build: `swift build --package-path /Users/moveax3/Projects/hand-control`
- Test: `swift test --package-path /Users/moveax3/Projects/hand-control` (Swift Testing)
- Run: `/Users/moveax3/Projects/hand-control/.build/debug/hand-control {record <name>|run [--debug]|list|delete <name>|cameras|camera-readers}`
- App: `/Users/moveax3/Projects/hand-control/scripts/build-app.sh [--install]` →
  `/Users/moveax3/Projects/hand-control/build/HandControl.app` (`--install` copies it to `~/Applications`
  and refuses while the app runs). Signs with the first "Apple Development" identity (`SIGN_IDENTITY`
  overrides): a stable signature keeps TCC grants across rebuilds, ad-hoc does not.
- Testing the app without permission prompts or real key events: run
  `build/HandControl.app/Contents/MacOS/HandControl` from the terminal with `HAND_CONTROL_DIR` pointing at
  a scratch dir holding a copy of `gestures.json` (the engine fails without gestures) and a
  `config.json` of `{"bindings": {}}`. TCC then attributes camera access to the terminal. Launching the
  bare binary any other way (Finder, `swift run HandControlApp`) has no usage string and TCC kills it.
- Data dir: `$HAND_CONTROL_DIR` or `~/.config/hand-control`; point it at a scratch dir for experiments.
- Event log: `~/Library/Logs/hand-control.log`, or `$HAND_CONTROL_DIR/hand-control.log` when set.
- Measuring cost: run with `HAND_CONTROL_DIR` pointing at a scratch copy of gestures and
  `{"bindings": {}}` — no key events, no Accessibility needed — and sample with
  `top -l 11 -s 1 -pid <pid> -stats pid,cpu,power`; include `appleh13camerad` (camera daemon).
  Run-to-run noise is ±2% CPU: alternate builds and repeat; one run proves nothing.
- Release vs debug build: no measurable CPU difference (Vision dominates); release saves ~30 MB.

## Constraints and pitfalls

- No third-party dependencies and no external window-manager CLIs; actions go through the `Action` enum.
- The CLI embeds `Support/Info.plist` via `-sectcreate` (Package.swift) so the binary carries a
  camera usage string. It does not make the binary TCC's responsible process.
- TCC permissions (Camera, Accessibility) usually attach to the app that launches the binary (the
  terminal); behavior depends on the launcher. Missing Accessibility makes `CGEvent.post` a silent no-op.
- Unverified on hardware: Vision's reporting of occluded joints (fist), and whether synthetic
  ctrl+arrow with `.maskSecondaryFn`/`.maskNumericPad` switches Spaces. Check with `run --debug`.
- `maxDistance` is RMS per-joint distance in palm lengths; the 0.25 default is uncalibrated.
- Tests with time: use steps exact in binary floating point (e.g. 0.125), or hold boundaries flake.
- Only `HandControlCore` is unit-testable; keep OS calls out of it.
- main.swift uses top-level `await`, which already drains the main queue: never call `dispatchMain()`
  (it traps). Keep the process alive with `parkForever`.
- Swift Testing's `#expect` cannot call mutating methods; compute into a local first.
- Camera readers depend on undocumented camera-daemon log lines; if `camera-readers` misbehaves after
  a macOS update, re-capture them with `log stream --info --predicate 'process ENDSWITH "camerad"'`
  and update the fixtures in `CameraClientsTests` (copy exact messages, never reconstruct them).
- Test clients that get killed without `stopRunning()` leave start lines without stops in the log:
  count streams by attribution add/remove, not by start/stop.
- `AVCaptureSession.startRunning/stopRunning` block; in the engine and app call them from the Engine
  actor, never the main thread (CLI `record` starting a tracker from top-level code is fine).
- The app bundle's Info.plist is `Support/App-Info.plist` (LSUIElement, Reactions gestures off); the
  CLI embeds `Support/Info.plist`. Keep the camera usage strings in both in sync.
- Nothing on the app's main thread may wait for `log show` (2–3 s per hour of history): the monitor
  reads history in the background and `snapshot()` only takes a lock.
