# hand-control

Trigger macOS hotkeys and system actions with hand gestures seen by your Mac's camera.

Record a pose once (a fist, a peace sign, whatever you like), bind it to a key combo such as
`ctrl+right` for the next Space, and show it to the camera. Everything runs locally with Apple's
Vision framework: no network, no third-party models, no frames stored.

- **Your own gestures.** Record 30 samples of any static hand pose; a nearest-neighbour classifier
  recognizes it regardless of where the hand is in the frame, how far it is, or how it is tilted.
- **Hotkeys and system actions.** Bind a gesture to any key combo, or to sleeping the Mac or its
  display.
- **Menu bar app.** Runs in the background with a status icon, pause (releases the camera),
  config reload and launch at login.
- **Who else is using the camera.** The menu shows how many other apps are streaming the camera and
  which processes may own the streams (best effort, see [below](#other-camera-readers)).
- **Light on resources.** After 3 s without a hand, tracking drops to 2 fps: measured at about
  3–6 % of one core on an M3 Pro while waiting for a hand.

Requires macOS 14 or later and Swift 6 (Xcode 16+). Developed and tested on an M3 Pro with
macOS 26 and the built-in FaceTime HD camera.

## Quick start

```sh
git clone https://github.com/andreygaag/hand-control.git
cd hand-control
swift build

# Record gestures: a 3 s countdown, then 30 samples. Move and tilt the hand a little.
.build/debug/hand-control record fist
.build/debug/hand-control record peace
.build/debug/hand-control list            # samples per gesture and how well they separate

# Bind them (see Configuration), then try it with per-frame output:
$EDITOR ~/.config/hand-control/config.json
.build/debug/hand-control run --debug
```

The first run asks for Camera access; hotkey bindings also need Accessibility. From a terminal
both are granted to the terminal app.

## Menu bar app

```sh
scripts/build-app.sh --install        # release build, signed, copied to ~/Applications
open ~/Applications/HandControl.app
```

Grant the app Camera and Accessibility on first launch, then use **Reload Config**; if an error
remains, quit and relaunch. The script signs with the first "Apple Development" identity in your
keychain (override with `SIGN_IDENTITY`). With ad-hoc signing (`SIGN_IDENTITY=-`) the app works,
but macOS asks for permissions again after every rebuild.

The icon is a filled hand while tracking, an outline hand while idle or starting, a crossed-out
hand when paused and a warning sign on error. The menu shows the exact state, the last gesture that
fired, the bindings and the other camera readers, and has Pause, Reload Config, Open Config, Open
Event Log and Launch at Login (available only for the installed copy).

The app does not watch its files: after editing `config.json` or recording a gesture, use Reload
Config. With the same data dir, the app, `hand-control run` and `hand-control record` exclude each
other ("hand-control is already running (pid N)"); quit the app to record.

## Configuration

`~/.config/hand-control/config.json` (created on first use; set `HAND_CONTROL_DIR` to use another
directory):

```json
{
  "holdMs": 300,
  "releaseMs": 300,
  "maxDistance": 0.25,
  "bindings": {
    "fist":  { "hotkey": "ctrl+right" },
    "peace": { "hotkey": "ctrl+left" },
    "sleep": { "system": "sleep" }
  }
}
```

| Key | Meaning |
|---|---|
| `holdMs` | How long a pose must be held before it fires. |
| `releaseMs` | How long the pose must be gone before the same gesture can fire again. |
| `maxDistance` | Reject threshold: average joint distance from the recorded samples, in palm lengths (0.25 = a quarter of a palm). |
| `bindings` | Gesture name → action. Recorded gestures without a binding still take part in recognition: record a `none` gesture of idle poses so that they never fire. |

Actions:

- `{"hotkey": "<modifiers>+<key>"}`. Modifiers: `ctrl`, `alt`/`opt`, `cmd`, `shift`, `fn`. Keys:
  `a`–`z`, `0`–`9`, `left`/`right`/`up`/`down`, `f1`–`f12`, `space`, `return`, `tab`, `esc`,
  `delete`, `forwarddelete`, `home`, `end`, `pageup`, `pagedown`, `-`, `=`, `[`, `]`, `;`, `'`, `,`,
  `.`, `/`, `\`, `` ` ``. Key codes are physical ANSI positions, independent of the input language.
- `{"system": "sleep"}` or `{"system": "displaySleep"}`, via `/usr/bin/pmset`.

To switch Spaces with `ctrl+left/right` or `ctrl+1..9`, enable those shortcuts under System
Settings → Keyboard → Keyboard Shortcuts → Mission Control.

## Commands

```
hand-control record <gesture> [--samples N] [--camera NAME]   record samples (appends)
hand-control run [--debug] [--camera NAME]                    recognize and fire actions
hand-control list                                             gestures, bindings, separation
hand-control delete <gesture>                                 forget a gesture's samples
hand-control cameras                                          list camera names for --camera
hand-control camera-readers                                   other camera streams, see below
```

`list` shows `nearest-other`, the smallest distance between a gesture and any other: below
`maxDistance` the two can be confused, so re-record one of them more distinctly.

## Troubleshooting

Significant events go to `~/Library/Logs/hand-control.log` (`tail -f` it, or use Open Event Log):
start, fires, misses, idle/active switches, pause/resume/reload, errors.

- **The hand is seen but nothing fires.** Look for
  `no gesture: hand shown N frames, closest fist d=0.31 (maxDistance 0.25)`: the pose was recognized
  but is too far from its samples. Re-record it the way you hold it now, or run `run --debug` to see
  per-frame distances.
- **A gesture fires by accident.** Record a `none` gesture from the poses that trigger it, or raise
  `holdMs`.
- **Hotkeys do nothing.** Accessibility is missing for the app (or terminal) running hand-control;
  without it macOS silently drops synthetic key events.

Hand rotation is ignored on purpose, so gestures that differ only by tilt (thumbs up vs thumbs
down) cannot be told apart. macOS Reactions use some of the same gestures (thumbs up, peace): the
app asks macOS to keep Reactions gesture detection off by default for itself, but a video call app
with Reactions on will still show balloons for your peace sign.

## Other camera readers

macOS has no public API that names the processes using the camera. hand-control reads the camera
daemon's log (`appleh13camerad` on the tested Mac): stream attributions give the number of
streams, client connections give the candidate processes. So the menu can say "2 other streams,
possible owners: zoom.us, Safari", but not which one owns which stream. Streams opened more than an
hour before launch are missed until they restart, the log messages are undocumented and may change
with any macOS update, and other cameras and camera daemons (USB, iPhone) are unverified.
`hand-control camera-readers` prints the same information in a terminal, counting a running Hand
Control app as a foreign stream.

## Privacy

Frames go from the camera to Apple's Vision framework in memory and are discarded. The only data
written to disk is `gestures.json` (21 joint coordinates per recorded sample, no images),
`config.json` and the event log. Nothing is sent over the network.

## Development

```sh
swift build && swift test      # tests need no camera or permissions
```

Pure logic (features, classifier, debouncer, config, log parsing) lives in `HandControlCore` and is
unit-tested; OS integration lives in `HandControlEngine`; the CLI and the menu bar app are thin
front ends. [ARCHITECTURE.md](ARCHITECTURE.md) describes the pipeline, invariants and the
measurements behind the design decisions; [CLAUDE.md](CLAUDE.md) holds commands and pitfalls for
coding agents.

## License

[MIT](LICENSE)
