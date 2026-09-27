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

Significant events (fires, misses, idle/active, pause/resume/reload, errors, start/stop) are logged to
`~/Library/Logs/hand-control.log`: `tail -f ~/Library/Logs/hand-control.log`.
After 3 s without a hand, tracking drops from 15 to 2 fps to save CPU; a gesture shown after a pause
may take up to 0.5 s longer to fire.

## Menu bar app

```sh
scripts/build-app.sh --install        # builds, signs, copies to ~/Applications
open ~/Applications/HandControl.app
```

It runs the same engine as `run` in the background. The icon is a filled hand while tracking, an
outline hand while idle or starting, a crossed-out hand when paused and a warning sign on error; the
menu shows the exact state. The menu has pause (releases the camera), reload config, open config /
event log, launch at login (only from the installed copy) and "other camera readers": how many other
camera streams are running and which processes may own them (best effort, from the system log; see
ARCHITECTURE.md).

The app does not watch its files: after editing `config.json` or recording a gesture, use
"Reload Config". With the same data dir, the app, `hand-control run` and `hand-control record`
exclude each other ("hand-control is already running (pid N)"): quit the app to record.

`hand-control camera-readers` prints the readers list in the terminal. It sees less than the menu:
a running Hand Control app counts as a foreign stream there, and "started a stream" marks come only
from live log lines, which a one-shot command rarely catches.

Grant the app Camera and Accessibility on first launch. After granting, use "Reload Config"; if the
error stays, quit and relaunch the app.

Permissions for the CLI: grant Camera and Accessibility to the terminal app you run it from. Switching spaces with
`ctrl+left/right` or `ctrl+1..9` requires those shortcuts to be enabled under
System Settings → Keyboard → Keyboard Shortcuts → Mission Control.

A miss is logged as `no gesture: hand shown N frames, closest fist d=0.31 (maxDistance 0.25)`: the
gesture was recognized but too far from its samples — re-record it the way you now hold it.
Hand rotation does not matter (gestures that differ only by tilt, like thumbs up vs down, cannot be
told apart).

`maxDistance` is the RMS per-joint distance in palm lengths (0.25 = joints a quarter of a palm off on
average). `run --debug` prints the per-frame candidate, its distance and why a frame was unreliable.
`list` prints samples per gesture and `nearest-other`, the smallest distance to another gesture: if it
is below `maxDistance`, the two gestures can be confused.
