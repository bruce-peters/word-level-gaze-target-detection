# WordGazeAR

A very simple Swift/ARKit port of the word-level gaze reader in [`web_app/`](../web_app) and
[`python_app/`](../python_app). Same two core mechanisms, nothing else:

- **Simple line tracking** — horizontal gaze position drives reading progress along a line.
- **Z-cut jumps** — a right→left return sweep (gaze reaches the right side of the line, then
  snaps back to the left) advances to the next line.
- **Huge-jump relocation** — if the reader's gaze sustainedly leaves the current line by more
  than a few sigma, it's treated as a real jump and the reading position relocates to the
  nearest sentence start.

Everything else in the reference apps (dynamic-Y calibration, the error-vector-cloud model,
LLM-assisted jump election) is deliberately left out — see `CODE_STUDY.md` at the repo root for
what those do, if you want to add them back later.

## The one thing that's actually different: the gaze source

The web/python apps estimate gaze from a **webcam** (WebGazer ridge regression, or an
L2CS-Net head-pose model). This app instead uses **ARKit's TrueDepth face tracking** and reads
the **per-eye transforms** ARKit already computes for you
(`ARFaceAnchor.leftEyeTransform` / `.rightEyeTransform`) — a much higher-fidelity signal than
head pose alone, since it's ARKit's own estimate of each eyeball's orientation, not just where
the head is pointed. See `Gaze/ARGazeEstimator.swift`.

Those per-eye transforms are turned into a `(pitch, yaw)` angle pair (in camera space), which
feeds into the exact same 9-point linear-regression calibration the Python app uses for its
head-pose features (`Gaze/Calibrator.swift`, ported from `python_app/gaze/calibration.py`) —
so any fixed sign/axis convention in how pitch/yaw were derived just becomes a regression
coefficient; it doesn't need to be geometrically exact.

## File map

```
WordGazeAR/
  WordGazeARApp.swift        entry point
  AppModel.swift              wires gaze -> calibration -> filter -> tracker -> UI
  Models/
    LayoutModel.swift         passage text, word/line/sentence layout   (ports reading/layout.py)
    Tracker.swift              Z-cut + huge-jump state machine           (ports reading/tracker.py)
  Gaze/
    ARGazeEstimator.swift      ARKit session + eye-transform -> pitch/yaw   (new: no python equivalent)
    Calibrator.swift            pitch/yaw -> screen point, linear regression (ports gaze/calibration.py)
    OneEuroFilter.swift          smoothing + forward prediction              (ports gaze/calibration.py)
  Views/
    ContentView.swift          phase switch + shared gaze-dot overlay
    WelcomeView.swift
    CalibrationView.swift      9-point hold-to-calibrate
    ReadingView.swift           passage + top bar + HUD, scroll-aware
    WordView.swift               single word, highlight state
    HUDView.swift                debug panel
```

## Requirements

- A **physical** iPhone or iPad with a **TrueDepth camera** (Face ID) — iPhone X or newer,
  iPad Pro 2018+. ARKit face tracking does not run in the Simulator.
- Xcode 15+, iOS 16+ deployment target (uses `Font(_ font: CTFont)` and modern SwiftUI).
- macOS + Xcode to build — this folder was written without an `.xcodeproj` since it was
  authored on a non-Mac machine; see setup below.

## Setup (creating the Xcode project)

This folder is just Swift source, not a buildable Xcode project yet. On a Mac:

1. **File → New → Project → iOS → App.**
   - Interface: **SwiftUI**. Language: **Swift**. Uncheck "Include Tests" if you don't need them.
   - Name it `WordGazeAR` (or whatever you like).
2. Delete the template's generated `ContentView.swift` and `WordGazeARApp.swift`.
3. Drag the `WordGazeAR/` folder from this repo into the Xcode project navigator
   ("Copy items if needed", add to your app target).
4. Add the camera usage description (required for ARKit's TrueDepth session):
   - Select the target → **Info** tab → add a row:
     `Privacy - Camera Usage Description` = "Used to estimate where you're looking on the screen, on-device only."
   - (In newer Xcode this is a build setting, `INFOPLIST_KEY_NSCameraUsageDescription`, if
     there's no separate `Info.plist` file in your project.)
5. Target → **General**: set **Minimum Deployments** to iOS 16.0+.
6. Target → **Signing & Capabilities**: pick your team so it can be installed on a device.
7. Plug in a supported device, select it as the run destination, and **Run**.

## Using it

1. **Welcome screen** → "Start calibration".
2. Hold your finger on each of the 9 red dots for about a second **while looking directly at
   it**; it turns green when done. All 9 → "Finish calibration".
3. Reading view starts automatically. The green dot is your filtered/predicted gaze; the red
   dot is the raw prediction. The current line is dimly highlighted, the current word is
   highlighted brighter.
4. Read a line left→right, then sweep your eyes back to the start of the next line — that
   return sweep is the Z-cut that advances `currentLine`.
5. Look away for a sustained stretch (e.g. skip to a different sentence) and it'll relocate to
   the nearest sentence start once the deviation is large and sustained enough (the huge-jump
   path) — tune via `JUMP_K` in `Tracker.swift` if it's too eager/reluctant.
6. Double-tap any word to force the reading position there by hand.
7. "Reset" restarts tracking from the top; "Recalibrate" redoes the 9-point calibration
   (useful if you moved the device or your head position changed a lot).

The bottom-right HUD mirrors `ui/hud.py`: current line/word, Z-cut reach/status, and the
huge-jump distance vs. threshold, so you can see *why* a jump did or didn't fire.

## Tuning

Same constants as the reference apps, same meanings — see `Models/Tracker.swift`:

| Constant | Default | Role |
|---|---|---|
| `Z_LEFT` / `Z_RIGHT` | 0.3 / 0.7 | Z-cut left/right regions (fraction of line width) |
| `Z_COOLDOWN_MS` | 500 | Z-cut debounce |
| `JUMP_K` | 4 | huge-jump threshold = k × σ |
| `HUGE_JUMP_SUSTAIN_MS` | 500 | deviation must persist this long to relocate |
| `HUGE_JUMP_COOLDOWN_MS` | 900 | settle window after a relocation |
| `EMA_ALPHA` | 0.25 | gaze smoothing for the huge-jump test |

If the Z-cut isn't firing on a real device (gaze rarely reaches the true screen edges), the
fix that helped most in the web/python apps was **lowering `Z_RIGHT`** (e.g. to 0.6) rather
than touching anything else — see `IMPROVING_LINE_JUMPS.md` at the repo root for the full
writeup of that failure mode.
