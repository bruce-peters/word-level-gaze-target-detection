# Word-Level Gaze Tracking

A reading tracker that follows **which line** (reliably) and **which word**
(best-effort) you're reading from eye gaze, and highlights it as you go. It
comes in three versions: a browser demo and a Python desktop app, both using a
webcam, and an iPhone/iPad app using ARKit's TrueDepth face tracking.

**Live web demo: <https://bruce-peters.github.io/word-level-gaze-target-detection/>**
It needs a desktop browser with a webcam. Allow camera access when asked. Gaze
estimation runs in the page and the video stays on your machine.

## What's in this repo

| Folder | What it is | Gaze source |
|---|---|---|
| [`web_app/`](web_app) | Browser demo (the live link above) | [WebGazer.js](https://webgazer.cs.brown.edu/) |
| [`python_app/`](python_app) | Tkinter desktop port of the web demo | [`uniface`](https://github.com/yakhyo/uniface) RetinaFace + MobileGaze (ONNX) |
| [`swift_app/`](swift_app) | WordGazeAR, a SwiftUI iOS app with dynamic X/Y calibration and per-word data collection | ARKit face tracking (TrueDepth) |
| [`viewer/`](viewer) | Local-only page for browsing sessions the iOS app uploaded | reads Supabase |
| [`supabase/`](supabase) | SQL migrations for the iOS app's `reading_sessions` table | |
| `arkit-demo-swift/` | Git submodule → [bruce-peters/arkit-swift](https://github.com/bruce-peters/arkit-swift), an ARKit face-tracking blend-shape demo | |

Design notes: [`CODE_STUDY.md`](CODE_STUDY.md), [`IMPROVEMENTS.md`](IMPROVEMENTS.md),
[`IMPROVING_LINE_JUMPS.md`](IMPROVING_LINE_JUMPS.md) (written against an earlier
version of `web_app/app.js`), and
[`swift_app/ARKIT_GAZE_RESEARCH.md`](swift_app/ARKIT_GAZE_RESEARCH.md).

To get the submodule too, clone with `git clone --recursive`, or run
`git submodule update --init` in an existing clone.

## How it works

This is a **geometric mapping + calibration layer, not a machine-learning
model.** Raw webcam gaze has ~4° / ~100–200px error, far too coarse to hit
individual words directly. Instead we lean on the *linear-reading assumption*
(text flows left→right, top→bottom, line after line). That lets us snap a noisy
gaze signal onto the most likely line, and then guess the word within that line.

The core ideas (from the RT²H paper, *See Where You Read with Eye Gaze Tracking
and Large Language Model*, arXiv:2409.19454; see `CODE_STUDY.md`):

- **Z-cut line switching.** The current line is locked. Horizontal gaze *x* is
  progress along it, which you can trust because a line is much wider than the
  gaze error. A return sweep advances one line: gaze reaches the right region
  of the line (past 70% of its width), then snaps back to the left region
  (under 30%).
- **Huge-jump relocation.** The only other way off a line. If the smoothed gaze
  stays far from the current line for 500 ms, the reading position jumps to the
  nearest sentence start. "Far" means more than *k* × the noise σ measured
  during calibration.
- **Word within line.** The current word is the one whose horizontal extent
  contains (or is nearest to) gaze *x*.
- **Dynamic calibration.** The iOS app has this. Every time a Z-cut confirms a
  line is finished, the line's average raw gaze Y is paired with its true Y and
  a rolling linear regression `Y' = k·Y + b` is refit. This corrects slow
  vertical drift without asking anything of the reader. The iOS app adds the
  same thing for X, using the extremes reached on each line. The web demo
  prototyped dynamic-Y but doesn't ship it (see the header of `web_app/app.js`).

## Run it

### Web demo (`web_app/`)

There is no build step and nothing to install. WebGazer loads from the jsDelivr
CDN, so you need an internet connection.

```bash
cd web_app
python3 -m http.server 8000
```

Open <http://localhost:8000> in Chrome or Edge and allow camera access. Camera
access needs `http://localhost` or `https://`. Opening `index.html` as a
`file://` URL will not work. If you serve the repo root instead,
<http://localhost:8000/> forwards to `web_app/`.

1. Click **Start calibration**. The camera starts and a 9-point grid appears.
2. **Click each of the 9 dots 5 times**, looking straight at your cursor each
   time. Dots turn green when they're done.
3. Click **Finish calibration & measure accuracy**, then **stare at the center
   dot** for about 3 s. It reports the mean error and the noise σ, compared with
   the line gap.
4. Click **Start reading** and read the passage normally, top to bottom.

**Keep your head still and stay at a consistent distance (~50–70 cm).** Even
lighting on your face matters a lot. If tracking drifts badly, click
**Recalibrate**.

The top bar has these controls:

- **Reset tracking** restarts from the top without recalibrating.
- **Settings** lets you choose which webcam to use.
- Toggles for the raw dot (red, the unfiltered WebGazer point), the calibrated
  dot (green, after One-Euro smoothing), the camera preview and the debug HUD.
- A font-size slider.

Double-click a word to move the reading position there by hand. The debug HUD
shows:

- the current line and word
- raw vs. filtered gaze
- why the Z-cut has or hasn't fired
- the huge-jump distance vs. its threshold
- what caused the last line change

### Python desktop app (`python_app/`)

You need Python 3 with Tkinter. The python.org installers for Windows and macOS
include Tkinter. On Debian/Ubuntu, run `sudo apt install python3-tk`.

```bash
cd python_app
python3 -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python main.py --mouse-debug   # no camera needed: the mouse stands in for gaze
python main.py                 # webcam + gaze model
python main.py --camera 1      # use another camera index
```

The first webcam run downloads the face-detection and gaze model weights
(~95 MB) into `~/.uniface/models`. See [`python_app/README.md`](python_app/README.md)
for details.

### iOS app (`swift_app/`)

You need a Mac with Xcode 15+ and a **physical** iPhone or iPad with a TrueDepth
(Face ID) camera, on iOS 16+. Face tracking doesn't run in the Simulator. No
`.xcodeproj` is committed (`*.xcodeproj` is gitignored), so you:

1. create a new SwiftUI iOS App project
2. drag in `swift_app/WordGazeAR/`
3. add the camera usage description
4. set your signing team
5. run on the device

The step-by-step setup, the Supabase upload config and usage notes are in
[`swift_app/README.md`](swift_app/README.md).

### Session viewer (`viewer/`)

This page browses the reading sessions the iOS app uploaded to Supabase. It
needs the project's `service_role` key in `viewer/config.js` (gitignored), so it
is **for local use only**. See [`viewer/README.md`](viewer/README.md).

## Limitations (be honest)

- **Line-level is the reliable target.** Word-level is *approximate* and will
  often be off by a word or two. That's expected on webcam hardware, not a bug.
- Accuracy degrades the moment you **move your head** or change distance.
- The Z-cut assumes **normal linear reading**. Heavy skimming, re-reading or
  jumping around will confuse line assignment. Huge-jump relocation and the
  double-click override help a little.
- Lighting and webcam quality dominate everything. Bad light means coarse gaze,
  which means poor tracking, whatever the mapping logic does.
- The web and desktop versions keep everything in memory: no backend, no
  persistence. Only the iOS app saves sessions (locally, plus an optional
  Supabase upload).

## Deployment

GitHub Pages serves the `main` branch root. The root `index.html` forwards to
`web_app/`, and `.nojekyll` makes Pages publish the files as-is. The Pages build
checks out submodules, which is why `.gitmodules` must map `arkit-demo-swift`
to its URL.
