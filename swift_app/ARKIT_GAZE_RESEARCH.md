# ARKIT_GAZE_RESEARCH — the ARKit sensing layer, and what's backing it

`CODE_STUDY.md` and `IMPROVEMENTS.md` (repo root) already ground the *reading*
half of this project — RT²H's line tracking, dynamic calibration, and the
reading-science literature behind fixation detection and linguistic priors.
This document covers the half those two never touch: **what's actually known
about using ARKit/TrueDepth face tracking as a gaze source**, and exactly
which piece of code in `WordGazeAR` each finding motivated.

It exists for two reasons: so every change in this pass has a citation behind
it, and so it can be lifted close to verbatim into the poster's methods /
related-work section.

---

## 1. The noise floor: what accuracy should we even expect?

**Greinacher, R. & Voigt-Antons, J.-N. (2020). *Accuracy Assessment of ARKit 2
Based Gaze Estimation.* HCI International 2020 (HCII), Springer LNCS.**
<https://link.springer.com/chapter/10.1007/978-3-030-49059-1_32>

Built a gaze tracker purely from ARKit 2's public APIs (per-eye yaw/pitch +
eyelid closure, linearly calibrated against on-screen targets) and measured
it in two user studies: **~3.18° mean error (~1.44cm on screen)**, calling
this "comparable... to other smartphone eye trackers" while using far fewer
resources and a higher sample rate than a webcam pipeline.

**Bignardi, G. et al. (2024). *(The limits of) eye-tracking with iPads.*
Journal of Vision, 24(7):1.** <https://pmc.ncbi.nlm.nih.gov/articles/PMC11223623/>

The most directly useful paper found for this project — a rigorous, modern
head-to-head of an iPad Pro's ARKit-based face tracking against a Tobii 4c
research-grade tracker, on the same tasks. Headline numbers:

- **Mean absolute error 3.61° (iPad) vs. 0.75° (Tobii)** on a fixation task.
- **Only ~50% of small (reading-scale, ~1.5°) saccades detected** on the
  iPad vs. Tobii; **regressions (backward re-reads) detected at only
  15–20%** of the Tobii rate.
- Systematic **horizontal edge compression**: saccade amplitude toward the
  screen edges is underestimated ("eye-trackers commonly lose view of the
  pupil when the eye rotates too far to the right or left").
- Systematic **bottom-of-screen degradation**: lower-screen saccades
  measured smaller than upper-screen ones, attributed to eyelids partially
  covering the pupil on downward gaze.
- **5–20% of observers hit catastrophic tracking failure** on some tasks,
  often traced to eyelids/eyelashes occluding the pupil.
- Their own conclusion for reading specifically: *"reading speed derived
  from the iPad acted as a robust proxy to correlate to saccade
  characteristics"* — i.e. even the paper's own authors reach for an
  aggregate, structure-exploiting signal instead of trusting raw per-sample
  gaze for reading tasks. That's the same reframe `IMPROVEMENTS.md` §0
  already made for the web app; this independently confirms it's the right
  call for ARKit specifically, not just for a noisy webcam.

**What this sets up:** the ~1.4–3.6° / ~1.4cm noise floor is real, is
documented on this exact hardware/API, and is large relative to a word's
width at comfortable reading font sizes. Every "smart inference over noisy
samples" mechanism below exists because of this number, not in spite of it.

---

## 2. Calibration procedure: pursuit beats fixed-point (already implemented)

Multiple independent studies (e.g. the pursuit-calibration literature summarized
at <https://pmc.ncbi.nlm.nih.gov/articles/PMC7141046/>) report smooth-pursuit
calibration beating standard 9-point fixed calibration on the same time
budget — **~0.84° vs. 1.39°** in one head-to-head. `CalibrationView`'s
Lissajous-path pursuit dot (already in this codebase, not new in this pass)
is exactly this technique. No code change here — just the citation this
choice was always missing.

---

## 3. What this pass changed, and why

### 3.1 Blink gating — `Gaze/ARGazeEstimator.swift`

Bignardi et al.'s catastrophic-failure cases are frequently traced to
eyelids/eyelashes occluding the pupil — i.e. a blink (or a closing/opening
eyelid) actively corrupts the estimate rather than just adding noise to it.
Standard eye-tracking practice is to reject samples during a blink rather
than let them feed downstream logic. `ARGazeEstimator` now reads the
`eyeBlinkLeft`/`eyeBlinkRight` blend shapes every frame and drops the sample
entirely above `BLINK_THRESHOLD = 0.5` — applied identically to both
pipelines below, so the comparison in §3.2 stays fair.

### 3.2 The Apple-`lookAtPoint` baseline pipeline — `ARGazeEstimator`, `AppModel`

`ARFaceAnchor.lookAtPoint` is Apple's own description: *"a position, in face
coordinate space, estimating the direction of the face's gaze."* Used
directly — no head-translation correction — this is the naive way most
ARKit-gaze sample code and tutorials map gaze to a screen point (see e.g. the
publicly available [AR-Eye-Tracker](https://github.com/Shiru99/AR-Eye-Tracker)
project), and it is exactly the "angle-only" failure mode
`ARGazeEstimator.swift`'s own v2 header already argued against (an
angle/direction estimate alone can't distinguish "same angle, head moved"
from "head still, eyes moved").

This pass ships it as a second, parallel gaze pipeline:

- same ARKit frame, same blink gate as the engineered ray/plane signal
  (§3.1) — a fair, paired comparison, no asymmetric sample dropout;
- calibrated by its own instance of the existing `Calibrator` class (already
  generic — see its own header comment — so no new calibration math was
  needed);
- measured by the exact same mean-error/std-dev formula
  `AppModel.finishAccuracyCheck` already used for the engineered pipeline,
  run on both sample sets.

This turns "does the engineered ray/plane geometry actually help, versus
just using ARKit's own signal" from an assertion in a code comment into an
on-device number, reported at the end of every calibration
(`accuracyResultText`), in Settings, and saved on every session
(`ReadingSessionPayload.oursErrorPx`/`baselineErrorPx`/etc.) so testing
accumulates an aggregate comparison across sessions, not one anecdote.

### 3.3 Position-dependent error model — `Gaze/ErrorModel.swift`, `Tracker.jumpSigma`/`fixationDispersionThreshold`

RT²H (the paper `CODE_STUDY.md` documents for the web app) already assumed
gaze error is worse near the horizontal edges and toward the bottom of the
screen, but that was only ever implemented for the web app
(`errorRange()`/`errorRangeY()` in `app.js`), tagged `[DEVIATION]` there as
"reproduces the *trend*, not the paper's exact heatmap" — because that
heatmap was never published.

Bignardi et al. independently reproduce the **same two effects**, specific
to ARKit/iPad face tracking: horizontal edge compression and bottom-of-screen
degradation (eyelid occlusion on downward gaze) — see §1. Two independent
sources agreeing on the *shape* of the effect, on two different sensing
technologies (webcam vs. TrueDepth face tracking), is a reasonable basis for
porting the same boost shape into Swift, where it never existed:
`ErrorModel.radius(baseSigma:fractionFromEdge:fractionFromTop:)`, feeding
`Tracker.jumpSigma` (huge-jump threshold) and `Tracker.fixationDispersionThreshold`
(word-level clustering tolerance, §3.4). Reading spends real time exactly
where this matters: every line sweeps to both edges, and later lines sit
lower on the screen.

### 3.4 Fixation detection — `Gaze/FixationDetector.swift`

**Salvucci, D.D. & Goldberg, J.H. (2000). *Identifying fixations and saccades
in eye-tracking protocols.* ETRA.** <https://doi.org/10.1145/355017.355028>

The standard I-DT (dispersion-threshold) algorithm: collapse a
spatially-coherent run of samples into one fixation, discard the fast-moving
samples between clusters (saccades) — because vision is suppressed during a
saccade, so those in-flight samples shouldn't be billed to whatever word they
happen to sweep across. `IMPROVEMENTS.md` §1 already designed this for the
web app; it was never actually built anywhere in this repo until now.

Doubly motivated here specifically: Bignardi et al. found ARKit resolves only
~50% of reading-scale saccades a research-grade tracker detects (§1) — the
raw per-sample signal *during* a saccade is close to noise on this hardware,
so trusting it for word-level decisions is trusting the part of the signal
that's most documented to be unreliable.

`FixationDetector` is an *online* I-DT variant (the paper describes offline
emission): it exposes `currentCentroid`, the running centroid of the
in-progress stable cluster, not just fixations that have already closed —
otherwise word highlighting would lag `minDurationMs` (~100ms) behind actual
reading, which reads as broken in a live demo. `Tracker.processGaze` now
takes this centroid as `fixationX` and holds the previous word while it's
nil (mid-saccade) rather than trusting the noisy transit sample. Line
tracking (Z-cut / huge-jump) is untouched — those already have their own
timing-robust logic and still run on the raw per-frame point every frame.

### 3.5 Preferred Viewing Location + length prior — `Tracker.assignWord`

**Rayner, K. (1979). *Eye guidance in reading: Fixation locations within
words.* Perception.** <https://doi.org/10.1068/p080021>
**Rayner, K. (1998). *Eye movements in reading and information processing:
20 years of research.* Psychological Bulletin.** <https://doi.org/10.1037/0033-2909.124.3.372>
**Kliegl, R., Grabner, E., Rolfs, M. & Engbert, R. (2004). *Length,
frequency, and predictability effects of words on eye movements in
reading.* European Journal of Cognitive Psychology.** <https://doi.org/10.1080/09541440340000213>

Two established effects, both already cited in `IMPROVEMENTS.md` §2/§5 for
the web app's future work, neither built anywhere until now:

1. Fixations land slightly **left of a word's true center**, not at it
   (Rayner 1979) — `assignWord` now scores against
   `xStart + PVL_OFFSET_FRACTION * width` instead of the raw center.
2. **Longer words draw more/longer fixations** and are fixated more
   reliably; short function words are frequently skipped outright (Rayner
   1998; Kliegl et al. 2004) — `assignWord` now breaks close calls near a
   word boundary toward the longer candidate via a small
   `LENGTH_PRIOR_WEIGHT * log(length)` bonus, rather than pure
   nearest-distance.

This is deliberately the zero-new-data-dependency slice of `IMPROVEMENTS.md`
§2 (length only, no SUBTLEX frequency table or LLM surprisal call) — see
"Explicitly out of scope" below.

---

## 4. Explicitly out of scope for this pass (future work)

- **HMM/Viterbi global decode of reading position** (`IMPROVEMENTS.md` §4,
  citing Rabiner 1989) — the highest-ceiling, highest-effort item; not
  attempted given the days-not-weeks timeline before the symposium.
- **SUBTLEX word-frequency norms / LLM surprisal** (`IMPROVEMENTS.md` §2,
  citing Brysbaert & New 2009; Smith & Levy 2013; Levy 2008) — the
  length-only prior above captures much of the same signal without a new
  data asset or network dependency.
- **Error-vector-cloud model + LLM-assisted jump election** — already
  explicitly out of scope per `swift_app/README.md`.
- Running the baseline (`lookAtPoint`) pipeline through its own `Tracker`/
  word-highlighting state machine — the comparison in §3.2 is scoped to
  on-screen point accuracy (the same metric §1's papers report, so this
  project's number is directly comparable to theirs), not a second parallel
  reading UI.

## 5. Tuning constants this pass introduced

| Constant | Where | Default | Role |
|---|---|---|---|
| `BLINK_THRESHOLD` | `ARGazeEstimator.swift` | 0.5 | Blend-shape blink coefficient above which a frame is dropped |
| `ErrorModel.edgeBoost` | `ErrorModel.swift` | 0.6 | Extra error-radius fraction at horizontal edges |
| `ErrorModel.bottomBoost` | `ErrorModel.swift` | 0.3 | Extra error-radius fraction toward the bottom of the passage |
| `FixationDetector.minDurationMs` | `FixationDetector.swift` | 100 | Minimum duration for a *reportable* fixation (does not gate `currentCentroid`) |
| `PVL_OFFSET_FRACTION` | `Tracker.swift` | 0.4 | Landing-position bias, as a fraction of word width from `xStart` |
| `LENGTH_PRIOR_WEIGHT` | `Tracker.swift` | 6 | Weight on `log(word length)` when breaking word-boundary ties |

All five are new, untuned-on-device constants — retune after the first
on-device pass, same as the existing `Z_LEFT`/`JUMP_K`/etc. table in
`swift_app/README.md`.
