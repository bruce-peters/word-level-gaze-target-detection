# Word Gaze Tracker — Python / Tkinter / MobileGaze port

Desktop port of the browser prototype (`../app.js`), swapping WebGazer.js for
a PyTorch/ONNX gaze-estimation model. Same reading-tracking core as the JS
version: Z-cut line switching + huge-jump relocation to the nearest sentence.
See `../README.md` for the underlying approach; this file only covers the
Python-specific setup.

Gaze estimation uses [`uniface`](https://github.com/yakhyo/uniface)'s
`RetinaFace` (face detection) + `MobileGaze` (gaze estimation, built on top
of [L2CS-Net](https://github.com/Ahmednull/L2CS-Net), trained on Gaze360,
running on ONNX Runtime). We originally wired up L2CS-Net's own `l2cs`
package directly, but its pretrained weights are only distributed via an
unofficial, unreliable Google Drive folder with no stable direct-download
link. `uniface` wraps the same underlying approach but downloads and
SHA-256-verifies its model weights automatically on first use — no manual
download step.

## Setup

```bash
cd python_app
python -m venv .venv
.venv\Scripts\activate        # Windows
pip install -r requirements.txt
```

That's it — no separate weights download. The first time `MobileGaze()` /
`RetinaFace()` run, `uniface` fetches their ONNX weights into
`~/.uniface/models` automatically.

CPU inference is fine for a gaze cursor; `uniface[cpu]` uses ONNX Runtime's
CPU provider. Install `uniface[gpu]` instead (and swap it in
`requirements.txt`) if you want CUDA acceleration.

## Run

```bash
python main.py                 # real webcam + gaze model
python main.py --mouse-debug   # no camera/model needed; mouse position stands in for gaze
python main.py --camera 1      # pick a specific camera index
```

If the camera or model fails to load, the app shows an error dialog with the
specific problem instead of silently doing nothing.

`--mouse-debug` is useful for developing/testing the calibration UI, Z-cut,
word highlighting, and HUD without a working webcam or model install — move
the mouse the way you'd move your eyes.

## Structure

- `gaze/uniface_gaze.py` — webcam capture + RetinaFace/MobileGaze inference
  on a background thread, producing `(pitch, yaw)` samples.
- `gaze/calibration.py` — One-Euro smoothing filter + the 9-point-click
  linear regression that maps `(pitch, yaw) -> screen (x, y)`, replacing
  WebGazer's internal regression.
- `gaze/mouse_fallback.py` — drop-in gaze source driven by the mouse, for
  testing without hardware.
- `reading/layout.py` — passage layout model (words/lines/sentences), built
  from Tkinter Canvas text measurements.
- `reading/tracker.py` — the Z-cut / huge-jump reading-position state
  machine, ported 1:1 from `app.js`.
- `ui/` — the Tkinter window, overlays (welcome/calibration/accuracy/
  settings), and debug HUD.

## Known simplifications vs. the JS version

- No dwell-time heatmap or JSON export — the shipped `app.js` doesn't
  actually implement these either (only the README described them), so
  there was nothing to port.
- Camera picker is index-based (`Camera 0`, `Camera 1`, ...) rather than
  showing real device labels, since Windows has no reliable label
  enumeration without extra dependencies.
