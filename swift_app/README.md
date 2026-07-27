# WordGazeAR

A simple Swift/ARKit port of the word-level gaze reader in [`web_app/`](../web_app) and
[`python_app/`](../python_app). Core mechanisms ported over:

- **Simple line tracking** — horizontal gaze position drives reading progress along a line.
- **Z-cut jumps** — a right→left return sweep (gaze reaches the right side of the line, then
  snaps back to the left) advances to the next line.
- **Huge-jump relocation** — if the reader's gaze sustainedly leaves the current line by more
  than a few sigma, it's treated as a real jump and the reading position relocates to the
  nearest sentence start. The sigma is *measured*, not guessed — see the accuracy-check step
  below.
- **Dynamic-Y calibration** — every time a Z-cut confirms a line is finished, that line's
  average raw gaze Y is paired with its known true Y and a rolling linear regression
  (`Y' = k·Y + b`) is refit, correcting slow vertical drift with zero user effort. Ported from
  `app.js`'s `fitRegression()`/`calibrateY()`/`finishCurrentLine()` (`CODE_STUDY.md` §4) —
  see `Gaze/DynamicYCalibrator.swift`.
- **Dynamic-X calibration** — the horizontal counterpart, and the "highest-value follow-up"
  `IMPROVING_LINE_JUMPS.md` recommended and never built. X sweeps across most of a line while
  reading it, so instead of one average per line, this pairs the raw-X *extremes* reached
  while reading a line against that line's true `xMin`/`xMax` on every Z-cut. Corrects the
  horizontal compression that's the documented root cause of the Z-cut not firing, and also
  improves word-within-line assignment (same corrected X feeds both). See
  `Gaze/DynamicXCalibrator.swift`; both dynamic calibrators share their rolling-OLS core,
  `Gaze/RollingLinearFit.swift`.
- **Read-trail highlighting** — every word up to the furthest point reached stays subtly
  tinted, distinct from the current line/word highlight. This is the paper's actual headline
  feature ("See Where You Read") — the mechanisms above exist to keep this trail accurate, but
  it was missing from the initial port; see `Views/WordView.swift`.

Left out on purpose: the error-vector-cloud model and LLM-assisted jump election — see
`CODE_STUDY.md` at the repo root for what those do, if you want to add them back later.

## Data collection

On top of the reading mechanics above, the app is a small research data-collection tool:

- **Home screen** — before calibration, the tester enters the participant's name, age, and
  reading proficiency (low/medium/high), and picks which passage to run from a bank of
  passages bundled as `passages.json`, each tagged `easy`/`medium`/`long`. See
  `Models/Passage.swift` and `Views/HomeView.swift`.
- **Per-word recording** — while reading, `Models/SessionRecorder.swift` watches the tracker's
  `currentWordID` every frame (fed by `AppModel.handleSample`/`forceRelocate`) and turns it
  into two things: an ordered **fixation trail** (every contiguous dwell on a word, in visit
  order, as `{word_index, word, seconds}` — revisits show up again) and a **heatmap** (the same
  visits aggregated by word, i.e. total seconds spent on each word in the passage).
- **Finish → Summary** — tapping "Finish" in `ReadingView` stops tracking, builds a
  `ReadingSessionPayload` (`Models/ReadingSessionPayload.swift`), always saves it locally first
  (`Services/SessionStorage.swift`, under the app's Documents/ReadingSessions/), then
  best-effort uploads it to Supabase (`Services/SupabaseClient.swift`) and shows the result on
  `Views/SessionSummaryView.swift`. A failed/offline upload just leaves the session "pending" —
  it stays safe on disk and can be retried from there, or in bulk from the "N sessions pending
  upload" row on the home screen (`AppModel.retryPendingUploads`).

### Supabase setup

Sessions are written to a `reading_sessions` table — schema in
`../supabase/migrations/0001_reading_sessions.sql` at the repo root, with an insert-only Row
Level Security policy for the `anon` role (the on-device app can write new rows but can't read
any back, including its own — that's what makes the embedded anon key "secure-ish" to ship in
the client).

To wire this up:

1. Run `0001_reading_sessions.sql` against your Supabase project (SQL editor, or via the
   Supabase MCP server once authenticated — see the repo root for the `claude mcp add` command
   already used to register it).
2. Fill in `Services/SupabaseConfig.swift`: `projectURL` is already set; `anonKey` is left
   blank — get it from the Supabase dashboard under **Project Settings → API → Project API
   keys → anon/public**, or ask for it to be fetched via the MCP server once authenticated.
3. Until `anonKey` is filled in, `SupabaseClient` throws `.notConfigured` on every upload
   attempt, but sessions still land safely as local JSON files — nothing is lost, uploads just
   stay pending until the key is set and a retry runs.

`passages.json` needs to ride along inside the `WordGazeAR/` folder when it's dragged into
Xcode (step 3 of Setup below) so it ends up in the app bundle — check its **Target Membership**
in the File Inspector if `PassageStore` reports zero passages at runtime.

## The one thing that's actually different: the gaze source

The web/python apps estimate gaze from a **webcam** (WebGazer ridge regression, or an
L2CS-Net head-pose model). This app instead uses **ARKit's TrueDepth face tracking** and reads
the **per-eye transforms** ARKit already computes for you
(`ARFaceAnchor.leftEyeTransform` / `.rightEyeTransform`) — a much higher-fidelity signal than
head pose alone, since it's ARKit's own estimate of each eyeball's orientation, not just where
the head is pointed. See `Gaze/ARGazeEstimator.swift`.

**Why it's (reasonably) robust to head movement.** The first version of this estimator used
only gaze *angle* (pitch/yaw relative to the camera) — but angle alone can't tell "same angle,
head moved 5cm sideways" apart from "head still, eyes moved," even though those land on very
different screen points. Fixed-angle calibration only holds for the head position it was
calibrated at. The estimator now uses each eye's **position**, not just its direction: it
intersects the eye's gaze ray with the camera's own image plane (`ARGazeEstimator.gazeScreenRay`),
which is a good approximation of the screen surface since the front TrueDepth camera sits
essentially flush with the glass. That intersection point is translation-aware by construction,
so head movement is handled geometrically instead of needing to be baked into a single frozen
linear fit. The `(gx, gy)` result (in meters, camera-local space) still feeds into the same
kind of small linear-regression calibration the Python app uses for its head-pose features
(`Gaze/Calibrator.swift`, ported from `python_app/gaze/calibration.py`) — now that job is just
to learn the small residual offset between the camera's image plane and the actual visible
screen rectangle, not to compensate for head position at all.

This is still an approximation (screen ≈ camera's own Z=0 plane; no per-device camera-to-screen
offset lookup), so don't expect pixel-perfect stability across a foot of head travel — but it
should hold up through normal reading posture shifts far better than angle-only ever could.

## File map

```
WordGazeAR/
  WordGazeARApp.swift        entry point
  AppModel.swift              wires gaze -> calibration -> filter -> tracker -> UI
  passages.json                bundled passage bank (easy/medium/long)     (new: see Data collection)
  Models/
    LayoutModel.swift         word/line/sentence layout for whatever passage text is set (ports reading/layout.py)
    Tracker.swift              Z-cut + huge-jump state machine           (ports reading/tracker.py)
    Passage.swift                Passage/PassageDifficulty + PassageStore (loads passages.json)  (new)
    ParticipantInfo.swift        name/age/proficiency captured on HomeView                          (new)
    SessionRecorder.swift        per-word fixation trail -> aggregated heatmap                       (new)
    ReadingSessionPayload.swift  wire format shared by local JSON + Supabase upload                  (new)
  Gaze/
    ARGazeEstimator.swift      ARKit session + eye ray/screen-plane intersection -> (gx,gy)  (new: no python equivalent)
    Calibrator.swift            (gx,gy) -> screen point, linear regression      (ports gaze/calibration.py)
    OneEuroFilter.swift          smoothing + forward prediction                  (ports gaze/calibration.py)
    RollingLinearFit.swift        shared rolling-OLS core for both dynamic calibrators
    DynamicYCalibrator.swift     rolling Y' = k*Y+b refit on every Z-cut          (ports app.js §4)
    DynamicXCalibrator.swift     rolling X' = k*X+b refit on every Z-cut          (new: app.js never had this)
  Services/
    SupabaseConfig.swift          project URL + anon key                                             (new)
    SupabaseClient.swift          POST a finished session to Postgres via PostgREST                  (new)
    SessionStorage.swift          local JSON backup + pending-upload tracking                         (new)
  Views/
    ContentView.swift          phase switch + shared gaze-dot overlay
    HomeView.swift               participant info + passage picker                                    (new)
    WelcomeView.swift
    CalibrationView.swift      smooth-pursuit dot-following calibration
    AccuracyCheckView.swift     final stare-at-a-dot step, measures noise σ
    SettingsView.swift          font size (+ read-only calibration diagnostics)
    ReadingView.swift           passage + top bar + HUD, scroll-aware
    SessionSummaryView.swift     post-Finish recap + upload status                                    (new)
    ReplayView.swift              3x-speed playback of the recorded fixation trail                    (new)
    WordView.swift               single word, line/word/read-trail highlight state (gated by showDebugOverlay)
    HUDView.swift                debug panel
    PillButtonStyle.swift        shared button chrome
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

1. **Home screen** → enter the participant's name, age, and reading proficiency, pick a
   passage, then "Continue" (see Data collection above). "Change" on the next screen comes back
   here if you need to fix something before calibrating.
2. **Welcome screen** → "Start calibration".
4. **Follow the moving dot with your eyes** for about 15 seconds — no tapping, no holding
   anything, just track it while keeping your head still. It sweeps a smooth Lissajous path
   across the whole screen; every gaze sample along the way is paired with the dot's position
   at that instant, so this one pass produces far more calibration data than a handful of
   discrete clicks would. If it can't get a good fit (e.g. you looked away partway through),
   it'll tell you and offer **Retry**, which restarts the same path from the beginning.
5. **Accuracy check**: stare at the single green dot for ~3 seconds without moving your head.
   This measures your gaze noise (mean error + standard deviation) and feeds the std-dev into
   `Tracker.state.calibStdPx`, which sets the huge-jump threshold (`JUMP_K × σ`) to *your*
   measured noise instead of a generic fallback. Tap "Start reading" once it reports a result.
6. Reading view starts automatically. By design, it shows **plain, unhighlighted text** — no
   gaze dots, no current-line/current-word highlight, no read-trail, no HUD. Any of that would
   give the participant live feedback about where the system thinks they're looking, which
   would bias how they read and undermine the point of collecting natural reading data. Every
   word visited still gets logged in the background regardless (see Data collection above).
7. Read a line left→right, then sweep your eyes back to the start of the next line — that
   return sweep is the Z-cut that advances `currentLine`, and also feeds that line's raw X/Y
   into the dynamic-X/Y regressions.
8. Look away for a sustained stretch (e.g. skip to a different sentence) and it'll relocate to
   the nearest sentence start once the deviation is large and sustained enough (the huge-jump
   path) — tune via `JUMP_K` in `Tracker.swift` if it's too eager/reluctant.
9. Double-tap any word to force the reading position there by hand — this is the one piece of
   feedback that's always visible (a brief flash on the tapped word), since it's a direct
   response to the reader's own action rather than passive gaze exposure.
10. "Settings" lets you change the passage font size (re-flows the layout live) and shows the
    measured calibration noise/error read-only. "Reset" restarts tracking from the top;
    "Recalibrate" redoes the whole pursuit calibration + accuracy check (useful if you moved the
    device or your head position changed a lot — this also resets both dynamic regressions).
    **"Show Debug"** reveals everything hidden in step 6 — raw/filtered gaze dots, current
    line/word highlighting, the read-trail, and the bottom-right HUD (mirrors `ui/hud.py`:
    current line/word, Z-cut reach/status, huge-jump distance vs. threshold, last-advance
    reason, and both dynamic regressions' `k`/`b`/pair counts) — for debugging tracking quality
    outside of an actual data-collection session. Off by default; toggles back to "Hide Debug".
11. **"Finish"** ends the session, saves it locally, attempts the Supabase upload, and shows the
    summary screen (duration, longest dwell times, upload status). **"Watch reading replay
    (3x)"** (`Views/ReplayView.swift`) plays back the just-recorded fixation trail at 3x speed —
    each word highlights for its recorded dwell time ÷ 3, auto-scrolling to follow — with the
    raw gaze dot (the same red dot from `showDebugOverlay`, replayed from
    `SessionRecorder.gazeTrail` at the same 3x rate) moving alongside it, so you can quickly
    sanity-check how well tracking actually followed the participant, without re-reading the
    whole passage in real time. `gazeTrail` is only ever held in memory for this — it's not part
    of `ReadingSessionPayload`, so it never gets persisted or uploaded. "Skip" bails out
    immediately; it also finishes on its own once the trail runs out. "Done" returns to the home
    screen with the participant fields prefilled, ready for the
    next passage.

## Tuning

Same constants as the reference apps, same meanings — see `Models/Tracker.swift`:

| Constant | Default | Role |
|---|---|---|
| `Z_LEFT` / `Z_RIGHT` | 0.3 / 0.7 | Z-cut left/right regions (fraction of line width) |
| `Z_COOLDOWN_MS` | 500 | Z-cut debounce |
| `JUMP_K` | 1.5 | huge-jump threshold = k × σ |
| `HUGE_JUMP_SUSTAIN_MS` | 500 | deviation must persist this long to relocate |
| `HUGE_JUMP_COOLDOWN_MS` | 900 | settle window after a relocation |
| `EMA_ALPHA` | 0.25 | gaze smoothing for the huge-jump test |

If the Z-cut isn't firing on a real device (gaze rarely reaches the true screen edges), the
fix that helped most in the web/python apps was **lowering `Z_RIGHT`** (e.g. to 0.6) rather
than touching anything else — see `IMPROVING_LINE_JUMPS.md` at the repo root for the full
writeup of that failure mode.
