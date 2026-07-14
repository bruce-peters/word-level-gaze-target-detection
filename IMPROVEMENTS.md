# Improving per-word / per-sentence reading-time estimates under noisy webcam gaze

**Goal:** stop fighting WebGazer's noise *pointwise* and instead exploit the
structure of reading — known text geometry, a reliable line-level signal, and a
century of eye-movement research — to make *smart inferences* about what is being
read, then aggregate those inferences into accurate per-word and per-sentence
reading times.

This document is a concrete change plan against the current `app.js`. Each
section says **what to change, why, which functions it touches, and the research
it rests on.** Every paper is linked at the bottom (and inline the first time it
appears) so you can review the primary sources on your own time.

---

## 0. The core reframe

The current pipeline attributes time *pointwise*: `onGaze` fires ~30×/s,
`assignWord(gx)` greedily picks the nearest word to that single noisy sample, and
`tickDwell` adds the elapsed milliseconds to it. Every stray sample — including
the samples captured *mid-saccade, when the eye is effectively blind* — pollutes
a word's total. That is the root of the "noisy data" problem.

Three facts let us do much better:

1. **Line-level timing is reliable; word-level is not.** Your own Z-cut already
   detects line entry/exit robustly because a line is far wider than the gaze
   error. So *measure time-per-line accurately (you can) and allocate it across
   words with a model (you should)* — never ask the noisy gaze to resolve a word
   on its own.
2. **Reading is saccades + fixations, not a continuous stream.** Time should be
   attributed to *fixations*, not raw samples.
3. **How long each word takes is partly predictable before anyone looks at it**
   — from word length, frequency, and predictability (surprisal). That gives a
   strong *prior* that gaze only has to *update*, not produce from scratch.

The rest of this document turns those three facts into code.

---

## 1. Attribute time to fixations, not raw samples

**Change:** insert an online **fixation-detection** stage between `onGaze` and
attribution. Collapse each cluster of near-stationary samples into a single
fixation `{x, y, tStart, tDur, nSamples}`; discard the fast-moving samples
between clusters (saccades). Only fixations feed `assignWord`, `tickDwell`, and
`matchRatio`.

**Why:** during a saccade (~20–40 ms) vision is suppressed — no reading happens —
yet those in-flight samples currently get billed to whatever word they sweep
over. Reading researchers *define* a word's "gaze duration" as the sum of its
fixation durations, precisely to exclude transit. Matching that definition is the
single cheapest noise reduction available here.

**Algorithm:** use **I-DT (dispersion-threshold)** or **I-VT
(velocity-threshold)** from Salvucci & Goldberg (2000) — both are ~20 lines and
run online. I-DT is more robust to WebGazer's jitter:

- Maintain a sliding window of recent samples.
- If the window's spatial **dispersion** `(maxX−minX)+(maxY−minY)` stays below a
  threshold (start ~1–1.5× the measured error radius, i.e. reuse
  `errorRange()`), keep extending the window → it's one fixation.
- When dispersion exceeds the threshold, emit the current window as a fixation
  (centroid = position, span = duration) and start fresh.
- Enforce a **minimum fixation duration** of ~80–100 ms so single stray samples
  don't become "fixations." Nyström & Holmqvist (2010) is worth reading for a
  more adaptive, noise-aware variant if I-DT proves too brittle on your camera.

**Code:**
- New module `detectFixations` (a small stateful object with `push(sample)` →
  optional emitted fixation).
- In `onGaze`, feed each `{calX, calY, now}` to it; act on emitted fixations
  instead of on every sample.
- `tickDwell(wordId, ts)` → `addFixationDwell(wordId, fixation.tDur)`.
- `matchRatio` should iterate over the **fixation** trajectory, not the raw
  sample trajectory — fewer, cleaner anchors, and the subsample-to-40 hack in
  the current `matchRatio` becomes unnecessary.

**Bonus signals you get for free:** fixation count per word and refixation rate —
both classic reading-difficulty measures (Rayner 1998).

*Papers:* Salvucci & Goldberg (2000); Nyström & Holmqvist (2010); Rayner (1998).

---

## 2. A linguistic prior on per-word reading time

**Change:** precompute, once per passage at load, a predicted reading-time
**cost** for every word from three well-established predictors, and store it on
the `WORDS[]` model (`w.costPrior`).

**The three predictors** (all established as robust effects on fixation
duration — Rayner 1998, 2009; Kliegl et al. 2004):

1. **Length** — longer words → longer/more fixations. You already have this
   (`w.text.length`, or better, box width `xEnd−xStart`).
2. **Frequency** — rarer words → longer fixations. Ship a compact frequency
   table from **SUBTLEX-US** (Brysbaert & New 2009). Use `−log(freq)`
   (equivalently Zipf value) as the regressor; unknown words get the rare-tail
   value.
3. **Predictability / surprisal** — less predictable words → longer reading
   times, and the relationship is **linear in *surprisal* = −log P(word |
   context)** (Smith & Levy 2013; grounded theoretically by Levy 2008). Model
   quality matters: better LMs give surprisal that predicts human RT better
   (Goodkind & Bicknell 2018; Wilcox et al. 2020) — so a modern model is a real
   upgrade over GPT-2-era estimates.

**Combine** into a per-word cost, e.g.:

```
costPrior_w = a + b·length_w + c·(−log freq_w) + d·surprisal_w
```

Start with coefficients from the reading literature (or just length+frequency if
you want zero API calls); refine later by fitting against your own exported data
(§6). This is, in miniature, the mechanism behind the **E-Z Reader** (Reichle et
al. 1998) and **SWIFT** (Engbert et al. 2005) computational models — both predict
fixation durations from exactly length/frequency/predictability.

**Where surprisal comes from — reuse the LLM you already integrate.** Today
`electWithLLM` only fires on rare jumps. Instead (or additionally) make **one**
call at passage load to get per-token log-probabilities and convert to per-word
surprisal (`−logprob`, summed over a word's sub-tokens). This is a far higher-value
use of the model than the jump election. If per-token logprobs are awkward with
your endpoint, a small local n-gram / distilled model over the passage is enough
to get the *ordering* of surprisal right.

**Code:**
- New `buildCostPriors()` called at the end of `buildLayout()` (after
  `buildSentences()`), writing `w.costPrior` and a per-line/per-sentence sum.
- New `frequency.js` data file (SUBTLEX-derived Zipf values for the passage's
  vocabulary; you only need the words that actually appear).
- New `fetchSurprisal(passageText)` async helper; cache results so it runs once.

*Papers:* Rayner (1998, 2009); Kliegl et al. (2004); Brysbaert & New (2009);
Smith & Levy (2013); Levy (2008); Goodkind & Bicknell (2018); Wilcox et al.
(2020); Reichle et al. (1998); Engbert et al. (2005).

---

## 3. Allocate reliable line-time to words via the prior (the headline change)

**Change:** this is where §1 and §2 pay off. When a line finishes (you already
have the exact hook: `finishCurrentLine`, fired by the Z-cut), you know a
**reliable total dwell for that line, `T_line`.** Split it across the line's
words in proportion to their prior cost, then *nudge* the split with whatever
within-line fixation evidence survived §1.

**Method:**

1. On line entry, timestamp it. On the Z-cut that ends it, compute
   `T_line = tExit − tEnter` (sum of fixation durations that fell on the line is
   even better — noise from glancing away is excluded).
2. Baseline allocation from the prior:
   `time_w = T_line · costPrior_w / Σ_{j∈line} costPrior_j`.
3. **Blend** with observed evidence: let `obs_w` be the fixation dwell §1
   attributed to word `w` on this line. Use a confidence-weighted mix
   `time_w = (1−λ)·priorAlloc_w + λ·(T_line · obs_w / Σ obs)`, where `λ` grows
   with how much clean fixation evidence you actually got (few fixations → trust
   the prior; many well-separated fixations → trust the gaze).
4. Sentence times fall out by summing member words (you already segment
   `SENTENCES`), and correctly handle sentences spanning line breaks.

**Why it works:** you have converted an *unreliable per-word measurement* into a
*reliable per-line measurement plus a principled split*. The prior guarantees
sensible relative times even when gaze is useless; the gaze evidence corrects the
prior where it's wrong. This is the literal "aggregate assumptions to get
accurate per-word data" your goal describes.

**Code:**
- Add `State.lineEnterTs`, set on line change; compute `T_line` in
  `finishCurrentLine`.
- New `allocateLineTime(lineIndex, T_line)` writing a *new* `State.wordTime{}`
  map (keep the raw `State.dwell{}` alongside it so you can A/B the heatmap:
  "raw dwell" vs "modeled time").
- Heatmap (`paintHeatmap`) and export (`btnDump`) read from `State.wordTime`.

*Papers:* Just & Carpenter (1980) — the "eye-mind" assumption that dwell reflects
processing time, i.e. the justification for treating line dwell as processing
time to be distributed; Rayner (1998).

---

## 4. Global decode of reading position (HMM / Viterbi) — the high-ceiling upgrade

**Change:** replace the greedy, memoryless `assignLine`/`assignWord` with a
**probabilistic sequence model** over reading position. This is the rigorous
version of "aggregate assumptions across time."

**Model:**
- **Latent state** `s_t` = index into `READORDER` (which word is being read).
- **Observation** = the fixation position from §1. **Emission model** =
  probability that a reader fixating word `s` produces that observed point —
  *you already have this*: it's your `ERROR_CLOUD` / `matchRatio` machinery,
  optionally biased by the preferred-viewing-location offset (§5).
- **Transition model** `P(s_{t+1} | s_t)` encodes reading dynamics:
  - ~85–90% forward by a small saccade (1–2 words; skips of short/predictable
    words allowed),
  - ~10–15% **regression** (backward) — a real, well-quantified phenomenon
    (Rayner 1998),
  - small probability of a long jump (your existing jump-reading case).

**Decode:**
- **Online:** a forward filter (or particle filter) gives the current MAP
  position each frame — a drop-in, noise-robust replacement for the current
  per-frame guess. A single stray fixation can no longer teleport the cursor,
  because the transition prior makes that path expensive.
- **Offline (after reading):** run **Viterbi / forward–backward** over the whole
  fixation sequence for the *best global* path. **Time-per-word = total duration
  the decoded path spends in each state** — this is your cleanest possible
  per-word estimate, and it naturally reconciles with the line-level totals from
  §3.

Rabiner (1989) is the standard, readable HMM reference for Viterbi /
forward–backward if you want the algorithms spelled out.

**Code:**
- New `readingHMM` module: `emissionLogProb(fix, wordId)` (wrap `matchRatio`),
  `transitionLogProb(fromId, toId)` (a parameterised reading-dynamics kernel),
  `stepForward(fix)` for online, `viterbi(fixations)` for offline.
- Online path swaps into `onGaze` behind a toggle next to `useJump`.
- Offline path runs on Stop and produces the final `State.wordTime` (can replace
  or cross-check §3's allocation).

*Papers:* Rabiner (1989); Rayner (1998) for the transition-model statistics
(regression rate, saccade amplitudes).

---

## 5. Cheap accuracy refinements to the gaze→word mapping

Small, independent improvements that make §1–§4 better:

- **Preferred Viewing Location.** Fixations don't land on word centers; they land
  just left of center, and landing position is systematic (Rayner 1979). Bias
  `assignWord`'s hit test and the HMM emission model with that offset instead of
  nearest-`[xStart,xEnd]`.
- **Reading-rate regularizer.** Normal reading ≈ 200–300 wpm ≈ ~4 words/s. Use it
  to *reject* decoded trajectories (or line-time splits) implying implausible
  word rates, and as a sanity band on `T_line / (#words)`.
- **Reading-aware vertical filter.** WebGazer's generic Kalman filter isn't
  reading-aware. Snap `calY` toward the current line's `yCenter` in proportion to
  the dynamic-Y regression's confidence — cuts the Y jitter that currently
  destabilises `updateJump`'s off-line test.
- **Optimal Viewing Position / refixation:** long words attract a second
  fixation; that fixation *count* is extra difficulty signal for §2/§3.

*Papers:* Rayner (1979); Rayner (1998, 2009).

---

## 6. Aggregate across reads and readers (turn estimates into a dataset)

If the end goal is an accurate *corpus* of per-word/per-sentence reading times,
single-session noise is best beaten statistically:

- **Repeated exposure.** Have the passage read multiple times / by multiple
  people. Per-word time becomes a **distribution**, and you can apply
  **hierarchical (partial-pooling) Bayesian shrinkage**: noisy single-read
  estimates get pulled toward the population mean *and* toward the linguistic
  prior (§2). This is exactly how psycholinguistic eye-tracking corpora are
  denoised.
- **Mixed-effects modeling.** Fit `RT ~ length + log_freq + surprisal +
  (1 | word) + (1 | reader)` on your exported logs (Baayen, Davidson & Bates
  2008; `lme4` — Bates et al. 2015). This *separates* "this word is genuinely
  slow" from "this reader is slow" from "that gaze sample was noisy" — the random
  effects absorb reader/word idiosyncrasy so the fixed effects give clean,
  generalisable per-word costs.
- **Validate against public corpora.** Sanity-check your per-word estimates and
  your surprisal pipeline against established eye-tracking-while-reading datasets:
  **GECO** (Cop et al. 2017), **Provo** (Luke & Christianson 2018, which ships
  predictability norms), and the **Dundee** corpus (Kennedy & Pynte 2005). If
  your modeled times correlate with theirs on shared vocabulary, the pipeline is
  working.

**Code:**
- Extend `btnDump` export to include, per word: modeled `wordTime`, raw `dwell`,
  fixation count, `costPrior`, length, `log_freq`, `surprisal`, plus session and
  reader ids — everything a mixed-effects fit needs.

*Papers:* Baayen, Davidson & Bates (2008); Bates et al. (2015); Cop et al.
(2017); Luke & Christianson (2018); Kennedy & Pynte (2005).

---

## 7. Suggested sequencing

| Order | Change | Effort | Payoff | Depends on |
|------:|--------|:------:|:------:|:-----------|
| 1 | **§1 Fixation detection** | Low | High — matches the research definition of gaze duration, removes saccade pollution | — |
| 2 | **§3 Line-time allocation** | Low–Med | High — converts reliable line time into clean word time | §1, §2 |
| 3 | **§2 Linguistic prior** (start length+freq, add surprisal) | Med | High — strong prior gaze only has to update | LLM/logprobs, freq table |
| 4 | **§5 PVL + rate + vertical filter** | Low | Medium — steadier mapping | §1 |
| 5 | **§6 Export + mixed-effects + corpus validation** | Med | High if the goal is a dataset | §1–§3 |
| 6 | **§4 HMM / Viterbi decode** | High | Highest ceiling — global, noise-robust, gives per-word times directly | §1, §2, error cloud |

**If you do only two things:** §1 + §3. They need no new dependency beyond a small
frequency table, reuse hooks that already exist (`finishCurrentLine`, the Z-cut),
and directly deliver the goal. Keep the outputs *beside* the current `dwell` so
you can A/B "raw" vs "modeled" live, exactly as the README already does for
dynamic-Y calibration.

---

## References

**System this repo reimplements**
- Yang, Yan & Du (2024). *See Where You Read with Eye Gaze Tracking and Large Language Model* (RT²H). arXiv:2409.19454. https://arxiv.org/abs/2409.19454

**Fixation / saccade detection**
- Salvucci & Goldberg (2000). *Identifying fixations and saccades in eye-tracking protocols.* ETRA. https://doi.org/10.1145/355017.355028
- Nyström & Holmqvist (2010). *An adaptive algorithm for fixation, saccade, and glissade detection in eyetracking data.* Behavior Research Methods. https://doi.org/10.3758/BRM.42.1.188

**Eye movements in reading (foundational)**
- Rayner (1998). *Eye movements in reading and information processing: 20 years of research.* Psychological Bulletin. https://doi.org/10.1037/0033-2909.124.3.372
- Rayner (2009). *Eye movements and attention in reading, scene perception, and visual search.* Quarterly Journal of Experimental Psychology. https://doi.org/10.1080/17470210902816461
- Rayner (1979). *Eye guidance in reading: Fixation locations within words.* Perception. https://doi.org/10.1068/p080021
- Just & Carpenter (1980). *A theory of reading: From eye fixations to comprehension.* Psychological Review. https://doi.org/10.1037/0033-295X.87.4.329
- Kliegl, Grabner, Rolfs & Engbert (2004). *Length, frequency, and predictability effects of words on eye movements in reading.* European Journal of Cognitive Psychology. https://doi.org/10.1080/09541440340000213

**Computational models of eye-movement control**
- Reichle, Pollatsek, Fisher & Rayner (1998). *Toward a model of eye movement control in reading* (E-Z Reader). Psychological Review. https://doi.org/10.1037/0033-295X.105.1.125
- Engbert, Nuthmann, Richter & Kliegl (2005). *SWIFT: A dynamical model of saccade generation during reading.* Psychological Review. https://doi.org/10.1037/0033-295X.112.4.777

**Surprisal / predictability and reading time**
- Levy (2008). *Expectation-based syntactic comprehension.* Cognition. https://doi.org/10.1016/j.cognition.2007.05.006
- Smith & Levy (2013). *The effect of word predictability on reading time is logarithmic.* Cognition. https://doi.org/10.1016/j.cognition.2013.02.013
- Goodkind & Bicknell (2018). *Predictive power of word surprisal for reading times is a linear function of language model quality.* CMCL. https://aclanthology.org/W18-0102/
- Wilcox, Gauthier, Hu, Qian & Levy (2020). *On the Predictive Power of Neural Language Models for Human Real-Time Comprehension Behavior.* arXiv:2006.01912. https://arxiv.org/abs/2006.01912

**Word frequency norms**
- Brysbaert & New (2009). *Moving beyond Kučera and Francis … SUBTLEX-US.* Behavior Research Methods. https://doi.org/10.3758/BRM.41.4.977

**Sequence decoding**
- Rabiner (1989). *A tutorial on hidden Markov models and selected applications in speech recognition.* Proceedings of the IEEE. https://doi.org/10.1109/5.18626

**Statistical aggregation**
- Baayen, Davidson & Bates (2008). *Mixed-effects modeling with crossed random effects for subjects and items.* Journal of Memory and Language. https://doi.org/10.1016/j.jml.2007.12.005
- Bates, Mächler, Bolker & Walker (2015). *Fitting linear mixed-effects models using lme4.* Journal of Statistical Software. https://doi.org/10.18637/jss.v067.i01

**Public eye-tracking-while-reading corpora (for validation)**
- Cop, Dirix, Drieghe & Duyck (2017). *Presenting GECO: An eyetracking corpus of monolingual and bilingual sentence reading.* Behavior Research Methods. https://doi.org/10.3758/s13428-016-0734-0
- Luke & Christianson (2018). *The Provo Corpus: A large eye-tracking corpus with predictability norms.* Behavior Research Methods. https://doi.org/10.3758/s13428-017-0908-4
- Kennedy & Pynte (2005). *Parafoveal-on-foveal effects in normal reading* (Dundee corpus). Vision Research. https://doi.org/10.1016/j.visres.2004.09.017

**Gaze estimator used here**
- Papoutsaki, Sangkloy, Laskey, Daskalova, Huang & Hays (2016). *WebGazer: Scalable Webcam Eye Tracking Using User Interactions.* IJCAI. https://webgazer.cs.brown.edu/
