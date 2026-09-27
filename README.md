# hand-control

Control macOS windows and spaces with hand gestures seen by the camera.

```sh
swift build
.build/debug/hand-control record fist      # 30 samples; vary the hand slightly
.build/debug/hand-control record peace
.build/debug/hand-control record none      # optional: idle poses that must never fire
$EDITOR ~/.config/hand-control/config.json
.build/debug/hand-control run --debug
```

`config.json`:

```json
{
  "holdMs": 300,
  "releaseMs": 300,
  "maxDistance": 0.25,
  "bindings": {
    "fist":  { "hotkey": "ctrl+right" },
    "peace": { "hotkey": "ctrl+left" },
    "fuk":   { "system": "sleep" }
  }
}
```

Action types: `{"hotkey": "<mods>+<key>"}` and `{"system": "sleep" | "displaySleep"}` (via `/usr/bin/pmset`).

Significant events (fires, idle/active, errors, start/stop) are logged to
`~/Library/Logs/hand-control.log`: `tail -f ~/Library/Logs/hand-control.log`.
After 3 s without a hand, tracking drops from 15 to 2 fps to save CPU; a gesture shown after a pause
may take up to 0.5 s longer to fire.

Permissions: grant Camera and Accessibility to the terminal app you run it from. Switching spaces with
`ctrl+left/right` or `ctrl+1..9` requires those shortcuts to be enabled under
System Settings → Keyboard → Keyboard Shortcuts → Mission Control.

`maxDistance` is the RMS per-joint distance in palm lengths (0.25 = joints a quarter of a palm off on
average). `run --debug` prints the per-frame candidate, its distance and why a frame was unreliable.
`list` prints samples per gesture and `nearest-other`, the smallest distance to another gesture: if it
is below `maxDistance`, the two gestures can be confused.
