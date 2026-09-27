# hand-control

Swift package, macOS 14+. Apple Vision hand pose → kNN gestures → hotkeys. See ARCHITECTURE.md.

## Commands

- Build: `swift build --package-path /Users/moveax3/Projects/hand-control`
- Test: `swift test --package-path /Users/moveax3/Projects/hand-control` (Swift Testing)
- Run: `.build/debug/hand-control {record <name>|run [--debug]|list|delete <name>|cameras}`
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
