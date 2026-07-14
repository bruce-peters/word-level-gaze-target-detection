# CODE STUDY — `app.js` as an explainable RT²H implementation

**Paper:** *See Where You Read with Eye Gaze Tracking and Large Language Model* — Sikai Yang, Gang Yan, Wan Du. arXiv:2409.19454. The paper's system is named **RT²H** (Reading Tracking + Real-Time Highlighting).

This document explains the **function of every method** in `app.js`, maps each one to the part of the paper it implements, and lists every place we deliberately depart from the paper (tagged **`[DEVIATION]`**, and also marked in the source comments).

---

## 1. The paper in one paragraph

A laptop webcam estimates gaze with ~2 cm error, but a text line is only ~4–5 mm tall, so a raw gaze point cannot be trusted to hit a line. RT²H bridges that gap with four mechanisms:

1. **Linear reading tracking** — while reading a line, horizontal gaze *x* is reliable ("progress along the line") because a line is far wider than the error. A right→left return sweep (a **Z-cut**) means "next line".
2. **Dynamic calibration** — after each line, pair its average raw gaze *Y* with the line's known *Y*, fit a rolling linear regression `Y_line ≈ k·Y_gaze + b`, and remap future *Y*. Corrects slow drift with zero user effort.
3. **Two gaze error models** — an *error-range* model (how far off gaze can be at a location) and an *error-vector-cloud* model (a 2-D Gaussian of offset vectors) used to reason about messy gaze.
4. **Jump reading + LLM** — when the reader jumps out of linear order, detect it, list candidate destinations (sentence starts), score each with the error cloud (a *match ratio*), keep the top 3, and let an LLM pick the most contextually plausible next sentence (+0.1 bonus). The winner becomes the new reading position.

Reported numbers we mirror: mean gaze error **1.9455 cm**; error-vector std devs **σx = 1.8471 cm, σy = 1.2289 cm**; **500** cloud samples; jump threshold **2.5 s**; Z-cut border **20 %** of line width; LLM = **GPT-4o mini**; LLM bonus **+0.1**; jump accuracy **84 %**.

---

## 2. Method-by-method reference

### §1 Passage rendering & layout model

| Method | What it does | Paper mapping |
|---|---|---|
| `renderPassage()` | Rebuilds the passage DOM, wrapping **every word in its own `<span.w>`** with a stable id. Real spaces are kept so the browser still wraps lines naturally. | Text substrate. The per-word span is what lets us report word-level position and highlight. |
| `buildLayout()` | Reads each span's `getBoundingClientRect()` (in **document** coordinates), groups words whose vertical centers are within `ROW_TOL = 12px` into **lines**, sorts lines top-to-bottom, and assigns each word an `orderIndex` (reading order = line-major, left→right). Produces `WORDS`, `LINES`, `READORDER`, then calls `buildSentences()`. | This is the **ground truth geometry** RT²H snaps gaze onto — the known line/word positions the error models and calibration are defined against. |
| `buildSentences()` | Walks words in reading order and splits into `SENTENCES` on `.` `!` `?` terminators (regex tolerates trailing quotes/dashes). Each sentence remembers its **first word** (`startWordId`) — the thing a jump can land on. | Paper §6: candidate jump destinations are **sentence starts found after punctuation marks**. |
| `finalizeSentence(s)` | Computes a sentence's bounding box (union of its word boxes: `xMin/xMax/yMin/yMax`) for fast hit-testing. | Support for match-ratio scoring (below). |

### §4 Dynamic-Y calibration

| Method | What it does | Paper mapping |
|---|---|---|
| `fitRegression()` | Ordinary least squares over the rolling `yPairs` to solve **Eq.(1)** `[k,b] = argmin Σ (Y_line − (k·Y_gaze + b))²`. Guards against degenerate/wild slopes (clamps `k` to [0.2, 5], falls back to a pure offset). | Paper Eq.(1), the dynamic line-gaze-alignment calibration. |
| `calibrateY(rawY)` | Applies **Eq.(2)** `Y' = k·Y + b` (X is passed through untouched — we trust it). Returns raw Y when the A/B toggle is off. | Paper Eq.(2). |
| `finishCurrentLine()` | On each completed line, averages that line's raw-Y samples, pairs it with the line's true `yCenter`, pushes the pair (rolling window `MAX_PAIRS = 12`), and refits. | The **pairing step** that feeds the regression — "average Y-axis raw gaze during a line ↔ actual line location". |

### §5 Gaze error models

| Method | What it does | Paper mapping |
|---|---|---|
| `PX_PER_CM`, `ERR_CM`, `ERR` | Constants. `ERR_CM` holds the paper's reported cm statistics; `ERR` exposes them as **pixels** and applies a runtime `_scale`. | The reported error statistics (1.9455 / 1.8471 / 1.2289 cm). |
| `calibrateErrorModel(measuredErrPx)` | Sets `ERR._scale = measuredErrPx / baseAvgPx`, so the *whole* model is rescaled to **this webcam's** measured error (from the accuracy check) while preserving the paper's x/y anisotropy, then rebuilds the cloud. | Grounds the abstract cm model in the actual device. **`[DEVIATION]`** — the paper uses its fixed 16-user statistics; we adapt magnitude to the live camera. |
| `errorRange(x,y)` | Returns the plausible error **radius (px)** at a screen location, scaling a base radius up near the left/right borders (+ up to 60 %) and toward the bottom (+ up to 30 %). | Paper's **error-range model**: "error is higher near the borders, especially left/right, and concentrates in the bottom." **`[DEVIATION]`** — we reproduce the *qualitative shape*, not the raw 16-user heatmap (which isn't published). |
| `errorRangeY(x,y)` | Vertical half-height of the current-line error band (scales `errorRange` by σy/avg). Decides "has gaze left this line?". | Vertical component of the error-range model, used by jump detection. |
| `buildErrorCloud()` | Precomputes **`CLOUD_N = 500`** offset vectors `{dx,dy}` drawn from a 2-D Gaussian with std devs `ERR.sigmaX`, `ERR.sigmaY`. | Paper's **error-vector distribution model** — "500 randomly sampled vectors ... form an oval cloud." |
| `gaussian()` | Standard-normal sampler via Box–Muller. | Sampling primitive for the cloud. |

### §5 (cont.) Linear reading: Z-cut line assignment

| Method | What it does | Paper mapping |
|---|---|---|
| `assignLine(gx,gy)` | Computes horizontal progress `normX` along the current line. Fires a **Z-cut** (advance one line + `finishCurrentLine()`) when the reader had reached the right region (`normX > Z_RIGHT = 0.8`) and then snaps back to the left region (`normX < Z_LEFT = 0.2`), respecting a `Z_COOLDOWN_MS = 500` debounce. A nearest-Y fallback runs **only when jump reading is disabled** (otherwise jump relocation owns off-line handling). Returns whether a Z-cut fired. | Paper's linear tracking: "directly use horizontal gaze as reading progress" + Z-cut return-sweep detection at **20 % of line width**. |
| `estimateLineGap()` | Median vertical spacing between consecutive line centers. | A geometric scale used by the fallback and the accuracy verdict. |
| `assignWord(gx)` | Within the current line, picks the word whose `[xStart,xEnd]` contains `gx`, else the horizontally nearest word. | Word-within-line resolution (best-effort; the paper is line-granular for reliability, word-level for progress). |

### §6 Jump reading detection

| Method | What it does | Paper mapping |
|---|---|---|
| `isActiveGaze(x,y)` | True when the gaze point falls inside the reading area (with padding). | Paper: **idle gaze (looking away) does not accumulate** toward the jump threshold. **`[DEVIATION]`** — the paper additionally uses idle/head cues we can't get from WebGazer's bare point stream; "inside the reader" is our proxy for "engaged." |
| `updateJump(gx,gy,ts)` | The per-sample jump state machine. If gaze is **active AND off the current line** (`|Y − lineY| > errorRangeY`), it accumulates elapsed time into `outsideMs` and records the point into `trajectory`. Returns `"jump"` once `outsideMs ≥ JUMP_TIME_MS (2500)`. If gaze returns onto the line, it resets the accumulator (it was not a jump). | Paper: **"2.5 s of accumulative active gazing outside the current line," gaze escaping the error-range model**, idle time excluded. |

### §6–7 Jump relocation: candidates → match ratio → LLM election

| Method | What it does | Paper mapping |
|---|---|---|
| `pointInSentence(px,py,s)` | Fast hit-test: is a point inside sentence `s`? Rejects on the sentence bbox first, then checks individual word boxes (± padding). | Support for match-ratio counting. |
| `matchRatio(sentence,traj)` | For each (subsampled, ≤40) gaze point on the jump trajectory, **attaches the 500-sample error cloud** and counts what fraction of samples land on the candidate sentence; averages over the trajectory. Returns 0–1. | Paper §6.2 **match ratio**: "attach the model onto each gaze location and count what percent of the cloud falls on a candidate sentence." Winners sit ≈0.3, as the paper notes. |
| `findCandidates(traj)` | Computes the **landing point** (mean of the last ~8 trajectory points), then collects every sentence start within `errorRange(landing)`. Widens the radius up to 4× if empty; last resort returns the single nearest sentence. | Paper: "search for punctuation marks **within error range** as potential destinations." |
| `relocate()` | The async pipeline: gather candidates → score by `matchRatio` → sort → take **top 3** → if >1 candidate, run `electWithLLM()` and add **+0.1** to its pick → choose the highest score → `applyRelocation()`. Freezes jump state (`relocating`) during the LLM round-trip and resets afterward. | Paper §6–7 candidate election end-to-end, including the **+0.1 LLM bonus** and the "skip the LLM when there's only one candidate" behavior. |
| `applyRelocation(sentence)` | Moves `currentLine`/`currentWordId` to the sentence's start word, extends the read trail, resets per-line bookkeeping, and flashes the destination. | The repositioning + highlight step ("See Where You Read"). |

### §7 LLM election

| Method | What it does | Paper mapping |
|---|---|---|
| `electWithLLM(top3)` | Builds the paper's prompt — *"The user was just reading: <<<Reading Material>>>, which option is most likely to be read next by the user?"* — with the reading history and the numbered top-3 candidates, POSTs to OpenAI **`gpt-4o-mini`** (temp 0), and parses back the chosen option index. Returns −1 (no bonus) if there is no key or the call fails. | Paper §7 verbatim in structure and model choice. **`[DEVIATION]`** — a static browser page can't hide an API key, so the call is **optional** and key-gated; with no key we **degrade gracefully** (skip the bonus), a fallback the paper never needs. |
| `readingHistoryText()` | The already-read text (reading order up to `maxOrderReached`), truncated to ~1200 chars, used as the LLM's "Reading Material" context. | Paper: LLM is fed the reading material + reading history before the jump. |
| `shortText(sentence,max)` | Renders a sentence's words to a short label for prompts/HUD. | Prompt/HUD formatting helper. |

### §Highlighting, trail, dwell

| Method | What it does | Paper mapping |
|---|---|---|
| `updateHighlights(wordId)` | Toggles the `line-active` and `word-active` classes as the position changes; advances `maxOrderReached`; repaints the read trail. | Real-time highlighting (the "H" in RT²H). |
| `paintReadTrail()` | Tints **every word up to the furthest point reached** with `read-trail`. | The paper's core benefit: highlight already-read content so you never lose your place after a line change. |
| `tickDwell(wordId,ts)` | Accumulates per-word dwell time (ignores gaps > 500 ms, e.g. tab switches). | Not in the paper — an analysis extra. **`[DEVIATION]`, additive.** |
| `paintHeatmap()` / `renderDwellList()` | Warm background proportional to dwell; top-8 dwell list. | Same — additive analytics. |
| `flashRelocation(el)` | Brief blue pulse on a relocation/force-move target. | UI affordance for the repositioning event. |

### The main loop & lifecycle

| Method | What it does | Paper mapping |
|---|---|---|
| `onGaze(data,ts)` | The WebGazer callback. Converts viewport→document coords, draws the raw dot, computes calibrated `calY` (Eq.2), stores per-line Y samples, then **either** runs `updateJump()` (→ `relocate()` on threshold) **or** normal linear `assignLine`/`assignWord`/highlight/dwell, and finally updates the HUD. | The runtime that orchestrates all four mechanisms per gaze sample. |
| `ensureWebgazer()` | Starts WebGazer with ridge regression, our gaze listener, in-memory-only storage, Kalman smoothing, hidden built-in dots. | Gaze source. The paper uses a dedicated tracker; **`[DEVIATION]`** — we use **WebGazer.js (webcam)** as the estimator. |
| `buildCalibTargets()` / `onCalibClick()` / `updateCalibProgress()` | Standard WebGazer 9-point × 5-click calibration. | Initial per-user calibration (RT²H assumes a calibrated tracker). |
| `runAccuracyCheck()` | Center-stare accuracy test; measures mean error in px and **feeds it to `calibrateErrorModel()`** so the error models match the live camera; shows a verdict vs. the line gap. | Grounds the error model; produces the per-device error the paper measures empirically. |
| `dblclick` handler | **Forced relocation** — double-click any word to move the reading position there by hand. | Paper's manual double-click override (reported ~0.28 per session). |
| `chk*` toggles, `llmKey` input, `btnDump` | A/B switches for each mechanism, the OpenAI key field, and a JSON export (now including the error-model state). | Instrumentation for study/demo. |
| `rebuild()`, `clamp`, `escapeHtml`, `setHudState`, resize handler | Utilities and init. | — |

---

## 3. Full list of deviations from the paper

Everything below is also flagged inline in `app.js` with `[DEVIATION]`.

1. **Units: cm → CSS pixels.** The paper is defined on a physical display in centimetres; a web page only knows CSS px. We convert with `PX_PER_CM = 96/2.54 ≈ 37.8` and, more importantly, **rescale the whole error model to the accuracy check's measured pixel error** (`calibrateErrorModel`). This keeps the paper's x/y ratio but adapts magnitude to the actual webcam. *Impact:* the error models are approximate, not the paper's exact empirical map.

2. **Error-range model shape is qualitative.** The paper's range model is a heatmap learned from 16 users. That dataset isn't published, so `errorRange()` reproduces the reported *trend* (worse near left/right borders and the bottom) with tunable boosts (+60 % sides, +30 % bottom), not the exact surface.

3. **Gaze estimator is WebGazer.js.** The paper uses a dedicated eye-tracking pipeline; we use a webcam via WebGazer with ridge regression + Kalman smoothing. This raises real-world error well above the paper's lab numbers, which is exactly why the error model is rescaled to the live device.

4. **"Active vs idle" gaze is approximated by "inside the reader area."** The paper excludes idle gaze using cues we don't have from WebGazer's point stream; we treat gaze inside the passage bounds as active.

5. **LLM call is optional and key-gated, with graceful degradation.** The paper always calls GPT-4o mini server-side. A static browser page can't hide a key, so the call runs only when the user pastes an OpenAI key; with no key we skip the +0.1 bonus and elect purely by match ratio. The prompt text, model (`gpt-4o-mini`), and +0.1 bonus otherwise match the paper.

6. **Match-ratio trajectory is subsampled (≤40 anchors).** Purely a performance bound so the 500-sample cloud scoring stays cheap in the browser; it does not change the definition, only its resolution.

7. **Additive features not in the paper:** per-word **dwell logging + heatmap**, the **JSON export**, and the live **debug HUD** are analysis/demo aids layered on top. They don't affect tracking.

8. **Sentence segmentation is a simple regex** (`.` `!` `?` with trailing quote/dash tolerance) rather than an NLP sentence splitter. Fine for the hardcoded passage; a different corpus with abbreviations (e.g. "Dr.") could mis-split.

---

## 4. What matches the paper faithfully

- Z-cut linear tracking at the **20 %** border threshold.
- Dynamic-Y calibration **Eq.(1)/(2)** exactly (rolling OLS `Y_line ≈ k·Y_gaze + b`).
- Error-vector cloud: **500** samples, anisotropic **σx > σy** from the reported values.
- Jump detection at **2.5 s** of accumulated active off-line gaze, escaping the error range.
- Candidate destinations = **sentence starts within error range**.
- **Match ratio** = fraction of the attached error cloud landing on a candidate, averaged over the trajectory.
- **Top-3** candidates, **LLM election** with the paper's prompt and **+0.1** bonus, single-candidate case skips the LLM.
- Forced-relocation **double-click** override.
