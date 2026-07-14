# Gaze Reader — webcam "which word am I reading" (MVP)

A browser-only prototype that tries to follow **which line** (reliably) and
**which word** (best-effort) you're reading, using nothing but a laptop webcam
via [WebGazer.js](https://webgazer.cs.brown.edu/).

This is a **geometric mapping + calibration layer, not a machine-learning
model.** Raw webcam gaze has ~4° / ~100–200px error — far too coarse to hit
individual words directly. Instead we lean on the *linear-reading assumption*
(text flows left→right, top→bottom, line after line) to snap a noisy gaze
signal onto the most likely line, and then guess the word within that line.

## How to run

No build step. Serve the folder with any static server (WebGazer needs a real
`http://` origin for camera access — `file://` will not work):

```bash
# from this folder, pick one:
python -m http.server 8000
# or
npx serve .
```

Then open <http://localhost:8000> in Chrome, and **grant camera permission**.

## Calibration routine

1. Click **1 · Calibrate**. The camera starts and a 9-point grid appears.
2. **Click each of the 9 dots 5 times**, looking directly at your cursor each
   time. Dots turn green when finished.
3. Click **Finish calibration & measure accuracy**, then **stare at the center
   dot** for ~3s. You'll get a mean-error estimate compared to the line gap.
4. Click **Continue**, then **2 · Start tracking** and read the passage
   normally, top to bottom.

**Keep your head still and stay at a consistent distance (~50–70 cm).** Even
lighting on your face matters a lot. If tracking drifts badly, recalibrate.

## What each piece does (build order)

| Piece | What it does |
|-------|--------------|
| Passage renderer | Every word is its own `<span>`; on load we read `getBoundingClientRect()` for each and build a layout model: per-word `{xStart,xEnd,yCenter,lineIndex}` and per-line `{yCenter, xMin, xMax}`. |
| Calibration | Standard WebGazer 9-point click calibration + a center-stare accuracy check. Tracking is disabled until it's done. |
| Raw gaze dot | Red dot at the raw WebGazer point (toggle in the top bar). |
| **Z-cut line switching** | Horizontal gaze *x* = progress along the current line (line width ≫ gaze error, so *x* is trustworthy). When gaze reaches the right region (>80%) and then snaps back to the left region (<20%), that's a **return sweep** → advance one line. |
| **Dynamic-Y calibration** | When a line finishes, we pair its **average raw gaze Y** with the line's **true yCenter**, keep a rolling set of pairs, and fit a linear regression `trueY ≈ k·rawY + b`. Future Y is remapped through it. This is the key drift-correction trick (RT2H). The green dot is the calibrated point; the red dot is raw. |
| Nearest-Y fallback | If calibrated Y disagrees strongly with the current line (>1.3 line-gaps away), snap to the nearest line by Y. Catches skips/regressions. |
| Word-within-line | Given the current line and horizontal *x*, pick the word whose `[xStart,xEnd]` contains (or is nearest to) *x*. Subtle word highlight, stronger line highlight. |
| Dwell logging + heatmap | Accumulate per-word dwell (ms) while it's the current word; warmer background = longer dwell. **Export dwell JSON** dumps to console and downloads a file. |
| Debug HUD | Bottom-right: state, current line/word, raw vs calibrated gaze, Z-cut flag, live regression `[k,b]`, pair count. |

## A/B test the calibration

The **dynamic-Y calib** checkbox toggles trick (A) on/off live. Read for
60–90s with it **on**, watch the green (calibrated) dot hug the lines; turn it
**off** and watch vertical drift creep back in as you shift in your seat.

## Limitations (be honest)

- **Line-level is the reliable target.** Word-level is *approximate* and will
  often be off by a word or two — that's expected on webcam hardware, not a bug.
- Accuracy degrades the moment you **move your head** or change distance. The
  dynamic-Y calibration corrects slow vertical drift but not large pose changes.
- The Z-cut assumes **normal linear reading**. Heavy skimming, re-reading, or
  jumping around will confuse line assignment (the nearest-Y fallback helps a
  little).
- Lighting and webcam quality dominate everything. Bad light = coarse gaze =
  poor tracking regardless of the mapping logic.
- No backend, no ML classifier, no persistence — all state is in memory and
  gone on refresh, by design.

## Files

- `index.html` — markup, controls, overlays, HUD.
- `styles.css` — large-type reading layout + overlay/dot styling.
- `app.js` — layout model, Z-cut, dynamic-Y regression, word mapping, dwell.
  The line-assignment (`assignLine`) and calibration (`fitRegression`,
  `finishCurrentLine`) logic is commented for iteration.
# word-level-gaze-target-detection
