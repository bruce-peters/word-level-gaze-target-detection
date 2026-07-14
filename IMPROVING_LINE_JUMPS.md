# IMPROVING LINE JUMPS — the "stuck on a line" failure

Status: **E (diagnostics) and B (adjacent-line Y advance) implemented & verified.** A, C, D remain as follow-ups.

---

## 1. The symptom

During a read, tracking follows along fine, then reaches a line where **the Z-cut never fires**. The system keeps reporting the reader is on that same sentence and never advances. Separately, the **dynamic-Y calibration "gets very messed up"** over the same period.

## 2. Root cause — two coupled failures

### 2a. Why it gets stuck
With **jump-reading ON, the old nearest-Y line fallback in `assignLine` was disabled** (`if (!State.useJump)`). That left the **Z-cut as the *only* mechanism that advances a line during normal reading**. The Z-cut requires **both**:

1. `maxNormXSeen > Z_RIGHT (0.8)` — gaze reached the rightmost 20 % of the line, **then**
2. `normX < Z_LEFT (0.2)` — gaze snapped back to the leftmost 20 %.

The common trap: **horizontal gaze compresses toward screen center**, so on a wide (92vw) line the reader's estimated `x` tops out around 0.65–0.75 and *never arms* condition 1. The return sweep can then never be recognized, and with the Y-fallback disabled, nothing else advances the line → **stuck**.

### 2b. Why calibration rots (the coupling)
`finishCurrentLine()` — which pairs a line's average raw-Y with its true `yCenter` and refits the rolling regression `Y_line ≈ k·Y_gaze + b` — **only runs on a Z-cut**. So:

- **Stuck line ⇒ no new Y pairs ⇒ the regression goes stale** and drifts with posture, uncorrected.
- If a Z-cut later fires on the **wrong** line, the raw-Y average is paired with the **wrong** `trueY`, poisoning the OLS fit. A few bad pairs skew `k,b`, Y goes off, more mis-assignment follows — a feedback loop.

The stuck line and the calibration corruption are the **same problem** seen from two angles.

## 3. Brainstorm (full menu)

**A. Make the Z-cut fire more reliably**
- Lower `Z_RIGHT` (0.8→~0.65), raise `Z_LEFT` (0.2→~0.3).
- Trigger on a leftward *sweep delta* (`normX` drops >0.5 in a short window) instead of absolute regions.
- **Adaptive horizontal reach**: learn the real max `normX` the user hits and treat that as "the right end".

**B. Don't let linear progress depend on the Z-cut** ✅ *implemented*
- Conservative **adjacent-line Y advance**: step ±1 line when calibrated Y clearly crosses toward the neighbor's center; reserve big moves for jump relocation.
- (Optional) stuck watchdog: force-advance if stuck too long while Y drifts down.

**C. Fix the root cause — horizontal calibration**
- **Dynamic-X calibration** mirroring Y: line starts x≈`xMin`, line ends x≈`xMax` → fit `x' = kx·x + bx`. Removes the compression that starves the Z-cut.

**D. Stop calibration self-poisoning**
- Guard the Y pairing (enough samples, low variance, small residual; reject outliers).
- Robust regression (Theil–Sen / median slope) so one bad pair can't wreck `k,b`.
- "Reset calibration" button.

**E. Observability** ✅ *implemented*
- Surface `maxNormXSeen` and the reason the Z-cut hasn't fired in the HUD.

## 4. What was implemented

### E — Z-cut diagnostics (HUD)
`recordZcutDiag(normX, now)` classifies the Z-cut state every sample; three HUD rows show it:

| HUD row | Meaning |
|---|---|
| **horiz reach** | `x=<current normX> max=<maxNormXSeen>` — how far right gaze has reached on this line |
| **Z-cut status** | e.g. `reach 0.65 < 0.8 — read righter`, `armed — awaiting return (x=0.31)`, `cooldown`, `last line`, `ready` |
| **last advance** | how the line last moved: `zcut` / `y-adv` / `jump` / `forced` / `nearest-Y` |

This makes the failure legible: if you see `reach 0.68 < 0.8` sitting still, that *is* the stuck case.

### B — Conservative adjacent-line Y advance
New `advanceLineByY(gx, gy, normX, now)`, called from `assignLine` when jump reading is on (it replaces the disabled global nearest-Y snap). Rules:

- Trigger only when `|Y − lineCenter|` is between **0.6** and **1.6 line gaps** (`Y_ADVANCE_FRACTION` … `Y_ADVANCE_MAX`).
  - Below 0.6 gap → still on the line, do nothing.
  - Above 1.6 gaps → that's a genuine **jump**, left to the jump-reading relocation (+ LLM), untouched.
- Step **exactly one line** in the drift direction; require the target line to actually be closer to the gaze than the current one.
- **Downward** steps call `finishCurrentLine()`, so the dynamic-Y regression keeps getting fresh pairs **even when the Z-cut never fires** — this directly breaks failure 2b.
- **Upward** re-reads clear `lineYSamples` (don't poison the pairing) and just step back.
- 400 ms cooldown (`Y_ADVANCE_COOLDOWN_MS`) prevents oscillation.

Synergy: because B advances the moment Y crosses ~0.6 gap, normal line transitions never accumulate toward the 2.5 s jump threshold (`updateJump` resets once Y is back near the new line center), so B also prevents ordinary reading from being misread as a jump.

### Files touched
- `app.js` — `State` (diag + `yAdvanceAt` fields), `hud` refs, `assignLine` (diag call + B call + advance tagging), new `recordZcutDiag`, new `advanceLineByY`, HUD writes in `onGaze`, `jump`/`forced` tags in `applyRelocation` and the dblclick handler.
- `index.html` — 3 new HUD rows (`hudReach`, `hudZReason`, `hudAdv`); cache bust `?v=3`.

## 5. Verification (headless, in-browser)

Drove synthetic gaze that reproduces the stuck case — horizontal reach capped at **0.65** (Z-cut can never arm) with only Y drifting downward:

| fed line | current line | reach | Z-cut status | advanced by |
|---|---|---|---|---|
| 0 | 0 | 0.65 | reach 0.65 < 0.8 — read righter | — |
| 1 | 1 | 0.65 | reach 0.65 < 0.8 — read righter | y-adv |
| 2 | 2 | 0.65 | … | y-adv |
| … | … | … | … | y-adv |
| 6 | 6 | 0.65 | reach 0.65 < 0.8 — read righter | y-adv |

→ line tracks perfectly **without any Z-cut**. Guard rails also confirmed:
- **Far jump** (gaze 5 lines away): B does **not** step (`stayedPut = true`) — left to the jump machinery.
- **Upward re-read** (from line 5, gaze up one line): steps back to line 4.

## 6. Recommended next steps (not yet done)

1. **C — dynamic-X calibration.** The real root cause of 2a is horizontal compression; fixing it lets the Z-cut fire naturally and makes word-within-line more accurate. Highest-value follow-up.
2. **D — guarded pairing + robust (Theil–Sen) regression.** B keeps feeding the regression, so protecting it from outlier pairs matters more now, not less. Add a "reset calibration" control.
3. **A — adaptive horizontal reach**, if we'd rather keep the Z-cut as the primary signal instead of leaning on B.

## 6b. Reintroducing jumps safely — the HUGE-jump relocator

Goal: bring jump behavior back **without** the noisy webcam causing random relocations. Assume the reader is in the normal (line-locked) flow almost always, and only relocate on a genuinely large move.

**Rule:** relocate when a **smoothed** gaze deviates from the current reading line by more than **`k × σ`**, sustained briefly — then **snap to the nearest punctuation (sentence start)** to the gaze.

- **σ (noise scale)** = the standard-deviation / error recorded during the accuracy check. `runAccuracyCheck()` now also computes `calibStdPx` = RMS spread of the stare samples around their mean (precision), with `measuredErrPx` and a line-gap estimate as fallbacks (`jumpSigma()`, floored at 12px).
- **k** = "how many sigmas is HUGE" (`State.jumpK`, default **4**, editable in the top bar). Threshold = `k·σ`, shown live in the HUD (`huge-jump dist` = `dist / thresh`).
- **Noise rejection:** the test runs on an EMA-smoothed gaze (`EMA_ALPHA = 0.25`) and requires the deviation to persist `HUGE_JUMP_SUSTAIN_MS = 500 ms`, so a single spike can't trigger it.
- **No oscillation:** after relocating, a `HUGE_JUMP_COOLDOWN_MS = 900 ms` settle window blocks re-triggering while the reader lands; the EMA is re-anchored to the new line.
- **Target = nearest sentence start** (`relocateToNearestPunctuation`), i.e. the closest word-after-punctuation to the gaze. No LLM, no error-cloud, no match-ratio — those stay in the advanced (line-lock-off) pipeline.

This runs **with** line-lock: `onGaze` → if locked, `detectHugeJump()`; on trigger relocate, otherwise normal Z-cut + word tracking.

**Verification (headless):**
- Reading noise (±38px ≈ 1.5σ) → **0** relocations.
- Huge sustained jump → **1** relocation, `advBy = "huge-jump"`, lands on a sentence start; staring at the destination afterward produced **no** oscillation (exactly one relocation, settled on the correct line).

## 6c. Scroll robustness

**Bug:** the jump detectors work in *document* space (gaze = viewport gaze + `scrollY`). Coordinate reconstruction across a scroll is correct, but a scroll makes every sample's document-Y jump by the scroll delta in one step. The EMA bridged that discontinuity and the huge-jump test read it as a large sustained deviation → **spurious relocation on scroll** (reproduced: a 300px scroll fired relocations 2 samples later).

**Fix:** a `scroll` listener re-seeds the gaze smoother (`gazeEMA = null`) and suppresses jump detection for a short settle window (`HUGE_JUMP_COOLDOWN_MS`, also clears the advanced-mode trajectory). Tracking/line-lock are unaffected.

**Verification:** eyes held on the same screen point while scrolling 300px → **0** relocations; a genuine (non-scroll) jump still relocates exactly once onto the correct sentence-start line.

## 7. Tuning knobs (current values)

| Constant | Value | Role |
|---|---|---|
| `Z_LEFT` / `Z_RIGHT` | 0.2 / 0.8 | Z-cut left/right regions |
| `Z_COOLDOWN_MS` | 500 | Z-cut debounce |
| `Y_ADVANCE_FRACTION` | 0.6 | min Y move (in line gaps) to step a line |
| `Y_ADVANCE_MAX` | 1.6 | above this (gaps) it's a jump, not a step |
| `Y_ADVANCE_COOLDOWN_MS` | 400 | anti-oscillation gap between Y advances |
| `State.jumpK` | 4 | HUGE-jump threshold = k × σ (editable in top bar) |
| `HUGE_JUMP_SUSTAIN_MS` | 500 | deviation must persist this long to relocate |
| `HUGE_JUMP_COOLDOWN_MS` | 900 | settle window after a relocation (no re-trigger) |
| `EMA_ALPHA` | 0.25 | gaze smoothing for the huge-jump test |
