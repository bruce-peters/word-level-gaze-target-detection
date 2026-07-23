/* ============================================================================
   Gaze Reader - a demo re-implementation of the core of RT²H
   ----------------------------------------------------------------------------
   Paper: "See Where You Read with Eye Gaze Tracking and Large Language Model"
          Sikai Yang, Gang Yan, Wan Du (arXiv:2409.19454). Internally the paper
          calls the system RT²H (Reading Tracking + Real-Time Highlighting).

   GOAL OF THIS FILE
     Track *where in the text the user is reading* from a plain laptop webcam,
     and highlight it, so a reader never loses their place. The hard part is that
     webcam gaze error (~2 cm) is far larger than a line of text (~4-5 mm), so we
     cannot trust a raw gaze point to hit a line, let alone a word. This demo
     closes that gap with the two mechanisms that survive contact with a real
     webcam:

       (1) LINEAR READING TRACKING - while reading a line normally, horizontal
           gaze x is a reliable "progress along the line" signal because a line
           is much wider than the gaze error. A right-to-left return sweep (a
           "Z-cut") means "go to the next line".            -> assignLine()

       (2) HUGE-JUMP RELOCATION - the line stays LOCKED otherwise. Only a
           vertical deviation bigger than k times the calibration noise, held
           for half a second, moves us off it, and then we snap to the nearest
           sentence start.                                  -> §6

     The paper's dynamic-Y calibration, error-cloud models and LLM sentence
     election were prototyped here but are not part of this demo build; see
     CODE_STUDY.md and the git history for that work.
   ============================================================================ */

"use strict";

/* ------------------------------------------------------------------ */
/* 0. Hardcoded passage                                               */
/* ------------------------------------------------------------------ */
const PASSAGE = [
  'A Hare was making fun of the Tortoise one day for being so slow.\n\n"Do you ever get anywhere?" he asked with a mocking laugh.\n\n"Yes," replied the Tortoise, "and I get there sooner than you think. I\'ll run you a race and prove it."\n\nThe Hare was much amused at the idea of running a race with the Tortoise, but for the fun of the thing he agreed. So the Fox, who had consented to act as judge, marked the distance and started the runners off.\n\nThe Hare was soon far out of sight, and to make the Tortoise feel very deeply how ridiculous it was for him to try a race with a Hare, he lay down beside the course to take a nap until the Tortoise should catch up.\n\nThe Tortoise meanwhile kept going slowly but steadily, and, after a time, passed the place where the Hare was sleeping. But the Hare slept on very peacefully; and when at last he did wake up, the Tortoise was near the goal. The Hare now ran his swiftest, but he could not overtake the Tortoise in time.',
];

/* ------------------------------------------------------------------ */
/* 1. Passage renderer + layout model                                 */
/* ------------------------------------------------------------------ */
const passageEl = document.getElementById("passage");

// layout model, rebuilt on load and on resize
let WORDS = []; // [{id,text,el,lineIndex,xStart,xEnd,yCenter,orderIndex,sentenceIndex}]
let LINES = []; // [{lineIndex,yCenter,xMin,xMax,width,wordIds:[...]}]
let SENTENCES = []; // [{index,startWordId,wordIds,xMin,xMax,yMin,yMax}]
let READORDER = []; // wordIds in reading order (line-major, then left→right)

function renderPassage() {
  passageEl.innerHTML = "";
  let wid = 0;
  PASSAGE.forEach((para) => {
    const p = document.createElement("p");
    // collapse the source whitespace, split on spaces
    para
      .trim()
      .split(/\s+/)
      .forEach((token) => {
        const span = document.createElement("span");
        span.className = "w";
        span.id = "w" + wid;
        span.dataset.wid = wid;
        span.textContent = token;
        p.appendChild(span);
        p.appendChild(document.createTextNode(" ")); // keep real spaces for wrapping
        wid++;
      });
    passageEl.appendChild(p);
  });
}

/* Build the layout model from actual rendered bounding boxes.
   Words that share (roughly) the same vertical center are grouped into a line.
   This is the ground truth we snap gaze onto. */
function buildLayout() {
  WORDS = [];
  const spans = passageEl.querySelectorAll("span.w");
  const rows = []; // temp: array of {yCenter, words:[]}
  const ROW_TOL = 12; // px; two words within this vertical distance = same line

  spans.forEach((el) => {
    const r = el.getBoundingClientRect();
    const yc = r.top + r.height / 2 + window.scrollY;
    const w = {
      id: parseInt(el.dataset.wid, 10),
      text: el.textContent,
      el,
      lineIndex: -1,
      xStart: r.left + window.scrollX,
      xEnd: r.right + window.scrollX,
      yCenter: yc,
      orderIndex: -1,
      sentenceIndex: -1,
    };
    WORDS.push(w);

    // find a row with a close yCenter, else make a new one
    let row = rows.find((rw) => Math.abs(rw.yCenter - yc) < ROW_TOL);
    if (!row) {
      row = { yCenter: yc, words: [] };
      rows.push(row);
    }
    row.words.push(w);
  });

  // sort rows top-to-bottom, assign line indices, build LINES model
  rows.sort((a, b) => a.yCenter - b.yCenter);
  READORDER = [];
  LINES = rows.map((row, i) => {
    let xMin = Infinity,
      xMax = -Infinity,
      ySum = 0;
    row.words.sort((a, b) => a.xStart - b.xStart);
    row.words.forEach((w) => {
      w.lineIndex = i;
      w.orderIndex = READORDER.length; // reading order = line-major, L→R
      READORDER.push(w.id);
      xMin = Math.min(xMin, w.xStart);
      xMax = Math.max(xMax, w.xEnd);
      ySum += w.yCenter;
    });
    return {
      lineIndex: i,
      yCenter: ySum / row.words.length,
      xMin,
      xMax,
      width: xMax - xMin,
      wordIds: row.words.map((w) => w.id),
    };
  });

  buildSentences();
}

/* Segment the passage into SENTENCES on . ! ? terminators (§2 of the paper:
   "search for punctuation marks as potential destinations"). Each sentence's
   FIRST word is the candidate a huge jump relocates to. */
function buildSentences() {
  SENTENCES = [];
  let cur = null;
  const ENDS = /[.!?]["')\]]*(?:-+)?$/; // word ends a sentence (allow trailing quotes/dashes)

  READORDER.forEach((wid) => {
    const w = WORDS[wid];
    if (!cur) {
      cur = { index: SENTENCES.length, startWordId: wid, wordIds: [] };
    }
    cur.wordIds.push(wid);
    w.sentenceIndex = cur.index;
    if (ENDS.test(w.text)) {
      SENTENCES.push(finalizeSentence(cur));
      cur = null;
    }
  });
  if (cur) SENTENCES.push(finalizeSentence(cur)); // trailing fragment
}

function finalizeSentence(s) {
  let xMin = Infinity,
    xMax = -Infinity,
    yMin = Infinity,
    yMax = -Infinity;
  s.wordIds.forEach((id) => {
    const w = WORDS[id];
    xMin = Math.min(xMin, w.xStart);
    xMax = Math.max(xMax, w.xEnd);
    yMin = Math.min(yMin, w.yCenter);
    yMax = Math.max(yMax, w.yCenter);
  });
  return { ...s, xMin, xMax, yMin, yMax };
}

/* ------------------------------------------------------------------ */
/* 2. State                                                           */
/* ------------------------------------------------------------------ */
const State = {
  tracking: false,
  calibrated: false,
  currentLine: 0,
  currentWordId: null,
  maxOrderReached: -1, // furthest reading-order index ever reached

  // Z-cut bookkeeping
  lastNormX: 0.5, // last horizontal position as fraction of line width
  maxNormXSeen: 0, // how far right we've read on the current line
  zcutFiredAt: 0,

  // diagnostics: why has / hasn't the Z-cut fired, and how did we last advance
  zcutDiag: { normX: 0, reach: 0, reason: "-" },
  lineAdvancedBy: "-", // "zcut" | "huge-jump" | "forced" | "-"

  // measured webcam accuracy (px), from the accuracy check
  measuredErrPx: null,

  // --- HUGE-jump relocation (the only way off a locked line besides a Z-cut) ---
  // Assume the reader is in the normal flow almost always; only relocate on a
  // deviation bigger than JUMP_K times the calibration noise. Then snap to the
  // nearest punctuation (sentence start).
  calibStdPx: null, // precision (noise std) measured during the accuracy check
  gazeEMA: null, // smoothed gaze {x,y}: noise rejection before the outlier test
  hugeJump: { overMs: 0, lastTs: 0 }, // sustain timer so one spike can't trigger
  hugeDbg: { dist: 0, thresh: 0 }, // for the HUD
};

// "How many sigmas is HUGE": bigger = harder to trigger a relocation.
const JUMP_K = 4;

/* ------------------------------------------------------------------ */
/* 3. Gaze dots + HUD                                                 */
/* ------------------------------------------------------------------ */
const rawDotEl = document.getElementById("rawDot");
const calDotEl = document.getElementById("calDot");
const hud = {
  state: document.getElementById("hudState"),
  line: document.getElementById("hudLine"),
  word: document.getElementById("hudWord"),
  raw: document.getElementById("hudRaw"),
  cal: document.getElementById("hudCal"),
  zcut: document.getElementById("hudZcut"),
  reach: document.getElementById("hudReach"),
  zreason: document.getElementById("hudZReason"),
  adv: document.getElementById("hudAdv"),
  huge: document.getElementById("hudHuge"),
};

/* ------------------------------------------------------------------ */
/* 4. Linear reading: line assignment (Z-cut) (paper §5)              */
/* ------------------------------------------------------------------ */
// thresholds as fractions of line width. Paper uses 20% borders; we relax to
// 30%/70% because webcam gaze compresses toward center and often never reaches
// the outer 20%, which would stop the Z-cut from ever firing.
const Z_LEFT = 0.3; // "left region" = leftmost 30%
const Z_RIGHT = 0.7; // "right region" = rightmost 30%
const Z_COOLDOWN_MS = 500;

/* Given the gaze point, decide the current line during LINEAR reading.
     1. horizontal progress normX along the CURRENT line (x is trustworthy).
     2. Z-cut: read into the right region, then snap back to left = next line.
   The line is otherwise LOCKED: Y is ignored here, so gaze wandering can't jump
   lines. Only detectHugeJump() can move us off a line by Y.
   Returns true if a Z-cut just fired (for HUD). */
function assignLine(gx) {
  let zcut = false;
  const line = LINES[State.currentLine];
  if (!line) return false;

  const normX = clamp((gx - line.xMin) / Math.max(1, line.width), 0, 1);

  const now = performance.now();
  const cooled = now - State.zcutFiredAt > Z_COOLDOWN_MS;

  // ---- Z-CUT: right region reached earlier, now snapped back to left ----
  if (
    cooled &&
    State.maxNormXSeen > Z_RIGHT &&
    normX < Z_LEFT &&
    State.currentLine < LINES.length - 1
  ) {
    State.currentLine++;
    State.maxNormXSeen = 0;
    State.zcutFiredAt = now;
    State.lineAdvancedBy = "zcut";
    zcut = true;
  } else {
    State.maxNormXSeen = Math.max(State.maxNormXSeen, normX);
  }

  // record WHY the Z-cut did / didn't fire, for the HUD
  recordZcutDiag(normX, now);

  State.lastNormX = normX;
  return zcut;
}

/* Explain the Z-cut state so it's visible in the HUD. The classic stuck case is
   "reach 0.68 < 0.80": horizontal gaze compresses toward center and never
   touches the right region, so the return sweep can never arm. */
function recordZcutDiag(normX, now) {
  const reach = State.maxNormXSeen;
  let reason;
  if (State.currentLine >= LINES.length - 1) reason = "last line";
  else if (now - State.zcutFiredAt <= Z_COOLDOWN_MS) reason = "cooldown";
  else if (reach <= Z_RIGHT)
    reason = `reach ${reach.toFixed(2)} < ${Z_RIGHT}, read righter`;
  else if (normX >= Z_LEFT)
    reason = `armed, awaiting return (x=${normX.toFixed(2)})`;
  else reason = "ready";
  State.zcutDiag = { normX, reach, reason };
}

// median spacing between consecutive line centers
function estimateLineGap() {
  if (LINES.length < 2) return 60;
  const gaps = [];
  for (let i = 1; i < LINES.length; i++)
    gaps.push(LINES[i].yCenter - LINES[i - 1].yCenter);
  gaps.sort((a, b) => a - b);
  return gaps[Math.floor(gaps.length / 2)] || 60;
}

/* ------------------------------------------------------------------ */
/* 5. Word-within-line (best-effort)                                  */
/* ------------------------------------------------------------------ */
function assignWord(gx) {
  const line = LINES[State.currentLine];
  if (!line) return null;
  let best = null,
    bestD = Infinity;
  line.wordIds.forEach((id) => {
    const w = WORDS[id];
    if (gx >= w.xStart && gx <= w.xEnd) {
      best = w;
      bestD = 0;
      return;
    }
    const d = gx < w.xStart ? w.xStart - gx : gx - w.xEnd;
    if (d < bestD) {
      bestD = d;
      best = w;
    }
  });
  return best ? best.id : null;
}

/* ------------------------------------------------------------------ */
/* 6. HUGE-jump relocation (noise-robust, works WITH line-lock)       */
/*     Assume the reader stays in the current flow almost always. Only  */
/*     relocate on a deviation larger than  JUMP_K x (calibration       */
/*     noise), measured on a SMOOTHED gaze and required to persist      */
/*     briefly so a single noisy webcam sample can never trigger it. On */
/*     trigger, snap to the nearest punctuation (sentence start).       */
/* ------------------------------------------------------------------ */
const HUGE_JUMP_SUSTAIN_MS = 500; // deviation must hold this long to count
const HUGE_JUMP_COOLDOWN_MS = 900; // settle time after a relocation (no re-trigger)
const EMA_ALPHA = 0.25; // gaze smoothing (lower = smoother / more lag)

// The noise scale the "huge" threshold is measured in: the standard deviation /
// error recorded during calibration. The floor scales with the line gap so that
// "HUGE" can never sit below ~1.5 line gaps. Otherwise normal line-to-line
// reading drifts past the threshold and the huge-jump fires on ordinary flow,
// resetting maxNormXSeen and starving the Z-cut.
function jumpSigma() {
  const gap = estimateLineGap();
  const s =
    State.calibStdPx || State.measuredErrPx || gap * 0.6 || 40;
  return Math.max(s, gap * 1.5);
}

// Smooth the gaze, then test how far it is (vertically, from the current line)
// relative to JUMP_K sigmas. Returns true once the deviation has persisted long
// enough. Always call it (it also maintains the EMA + timer).
function detectHugeJump(gx, gy, now) {
  if (!State.gazeEMA) State.gazeEMA = { x: gx, y: gy };
  else {
    State.gazeEMA.x = EMA_ALPHA * gx + (1 - EMA_ALPHA) * State.gazeEMA.x;
    State.gazeEMA.y = EMA_ALPHA * gy + (1 - EMA_ALPHA) * State.gazeEMA.y;
  }
  const cur = LINES[State.currentLine];
  if (!cur) return false;

  const thresh = JUMP_K * jumpSigma();
  // deviation from the CURRENT reading line (vertical is what a real jump moves;
  // within-line horizontal drift is normal flow and handled by word tracking).
  const dist = Math.abs(State.gazeEMA.y - cur.yCenter);
  State.hugeDbg = { dist, thresh };

  const hj = State.hugeJump;
  const dt = hj.lastTs ? clamp(now - hj.lastTs, 0, 500) : 0;
  hj.lastTs = now;
  // settle window right after a relocation: keep smoothing but don't re-trigger
  if (hj.cooldownUntil && now < hj.cooldownUntil) {
    hj.overMs = 0;
    return false;
  }
  if (dist > thresh) {
    hj.overMs += dt;
    if (hj.overMs >= HUGE_JUMP_SUSTAIN_MS) return true;
  } else {
    hj.overMs = 0;
  }
  return false;
}

// Find the closest punctuation (sentence start) to a point and start there.
function relocateToNearestPunctuation(px, py) {
  let best = null,
    bestD = Infinity;
  SENTENCES.forEach((s) => {
    const w = WORDS[s.startWordId];
    const cx = (w.xStart + w.xEnd) / 2;
    const d = Math.hypot(cx - px, w.yCenter - py);
    if (d < bestD) {
      bestD = d;
      best = s;
    }
  });
  if (!best) return;
  const w = WORDS[best.startWordId];
  State.currentLine = w.lineIndex;
  State.currentWordId = w.id;
  State.maxNormXSeen = 0;
  State.lineAdvancedBy = "huge-jump";
  // reset detectors, re-anchor the EMA to the new line, and start a settle
  // window so we don't immediately re-trigger while the reader lands.
  State.hugeJump.overMs = 0;
  State.hugeJump.cooldownUntil = performance.now() + HUGE_JUMP_COOLDOWN_MS;
  State.gazeEMA = { x: px, y: w.yCenter };
  if (w.orderIndex > State.maxOrderReached)
    State.maxOrderReached = w.orderIndex;
  updateHighlights(w.id);
  flashRelocation(w.el);
}

/* ------------------------------------------------------------------ */
/* 7. Highlighting                                                    */
/* ------------------------------------------------------------------ */
let prevLine = -1,
  prevWord = null;

function updateHighlights(newWordId) {
  // line highlight
  if (State.currentLine !== prevLine) {
    if (LINES[prevLine])
      LINES[prevLine].wordIds.forEach((id) =>
        WORDS[id].el.classList.remove("line-active")
      );
    if (LINES[State.currentLine])
      LINES[State.currentLine].wordIds.forEach((id) =>
        WORDS[id].el.classList.add("line-active")
      );
    prevLine = State.currentLine;
  }
  // word highlight
  if (newWordId !== prevWord) {
    if (prevWord != null && WORDS[prevWord])
      WORDS[prevWord].el.classList.remove("word-active");
    if (newWordId != null && WORDS[newWordId]) {
      WORDS[newWordId].el.classList.add("word-active");
      const oi = WORDS[newWordId].orderIndex;
      if (oi > State.maxOrderReached) State.maxOrderReached = oi;
    }
    prevWord = newWordId;
  }
}

// brief blue pulse when a relocation moves the reading position
function flashRelocation(el) {
  el.classList.add("reloc-flash");
  setTimeout(() => el.classList.remove("reloc-flash"), 900);
}

/* ------------------------------------------------------------------ */
/* 8. WebGazer gaze listener: the main loop                           */
/* ------------------------------------------------------------------ */
/* ---- One-Euro filter (jitter reduction with low lag) --------------------
   The webcam signal is noisy AND laggy. A plain average trades one for the
   other; the One-Euro filter adapts: it smooths hard when the eye is still
   (kills jitter) but opens up during fast motion (barely adds lag). We run one
   per axis on the raw VIEWPORT gaze (viewport is continuous across scroll, so
   the filter never sees the scroll discontinuity). It also returns velocity,
   which we use to predict slightly forward and hide the remaining latency. */
function OneEuro(minCutoff, beta, dcutoff) {
  this.minCutoff = minCutoff;
  this.beta = beta;
  this.dcutoff = dcutoff;
  this.xPrev = null;
  this.dxPrev = 0;
  this.tPrev = null;
}
OneEuro.prototype._alpha = function (cutoff, dt) {
  const tau = 1 / (2 * Math.PI * cutoff);
  return 1 / (1 + tau / dt);
};
OneEuro.prototype.reset = function () {
  this.xPrev = null;
  this.dxPrev = 0;
  this.tPrev = null;
};
OneEuro.prototype.filter = function (x, t) {
  if (this.xPrev === null) {
    this.xPrev = x;
    this.tPrev = t;
    return { value: x, velocity: 0 };
  }
  let dt = t - this.tPrev;
  if (!(dt > 0)) dt = 1 / 60;
  this.tPrev = t;
  const dx = (x - this.xPrev) / dt;
  const aD = this._alpha(this.dcutoff, dt);
  const dxHat = aD * dx + (1 - aD) * this.dxPrev;
  this.dxPrev = dxHat;
  const cutoff = this.minCutoff + this.beta * Math.abs(dxHat);
  const a = this._alpha(cutoff, dt);
  const xHat = a * x + (1 - a) * this.xPrev;
  this.xPrev = xHat;
  return { value: xHat, velocity: dxHat }; // velocity in px/sec
};

// Tunables. minCutoff↓ = smoother (more lag); beta↑ = snappier on motion.
// beta must stay SMALL for noisy webcam gaze: the adaptive cutoff is
// minCutoff + beta·|velocity|, and if the velocity estimate is inflated by
// noise a large beta blows the cutoff wide open and the smoothing turns itself
// off. dcutoff is LOW so the velocity used for both the cutoff and the forward
// prediction is heavily smoothed (reflects real motion, not per-frame noise).
const FILTER_MIN_CUTOFF = 0.6; // Hz
const FILTER_BETA = 0.006;
const FILTER_DCUTOFF = 0.4; // Hz, smooth the velocity a lot
// Forward prediction to compensate pipeline latency. Projects the point along
// its (smoothed) velocity by this many ms. Kept modest and HARD-CLAMPED so a
// noisy velocity spike can never fling the dot across the screen. 0 = off.
let LEAD_MS = 25;
const PREDICT_CLAMP_PX = 35; // max prediction offset per axis

const oeX = new OneEuro(FILTER_MIN_CUTOFF, FILTER_BETA, FILTER_DCUTOFF);
const oeY = new OneEuro(FILTER_MIN_CUTOFF, FILTER_BETA, FILTER_DCUTOFF);
function resetGazeFilters() {
  oeX.reset();
  oeY.reset();
}

function onGaze(data, ts) {
  if (!data) return;
  const now = ts || performance.now();
  const tSec = now / 1000;

  // raw viewport point WebGazer reported this frame
  const vxRaw = data.x,
    vyRaw = data.y;

  // One-Euro smooth + small forward prediction (latency compensation).
  // The prediction offset is hard-clamped so a noisy velocity spike can never
  // fling the dot across the screen.
  const sx = oeX.filter(vxRaw, tSec);
  const sy = oeY.filter(vyRaw, tSec);
  const lead = LEAD_MS / 1000;
  const predX = clamp(sx.velocity * lead, -PREDICT_CLAMP_PX, PREDICT_CLAMP_PX);
  const predY = clamp(sy.velocity * lead, -PREDICT_CLAMP_PX, PREDICT_CLAMP_PX);
  const vx = sx.value + predX;
  const vy = sy.value + predY;

  // red "raw" dot = the UNFILTERED WebGazer point (so you can compare the lag)
  rawDotEl.style.left = vxRaw + "px";
  rawDotEl.style.top = vyRaw + "px";

  if (!State.tracking) return;

  // everything downstream uses the filtered+predicted point, in DOCUMENT coords
  const calX = vx + window.scrollX;
  const calY = vy + window.scrollY;

  // green "calibrated" dot = processed (filtered + predicted)
  calDotEl.style.left = calX - window.scrollX + "px";
  calDotEl.style.top = calY - window.scrollY + "px";

  const rawTrueX = vxRaw + window.scrollX,
    rawTrueY = vyRaw + window.scrollY;

  // ---- line assignment ----
  // The line stays locked; the only ways off it are a Z-cut (return sweep to the
  // next line) or a HUGE jump (relocate to nearest punctuation). Everything is
  // driven by X plus the huge-jump outlier test.
  let zcut = false;
  if (detectHugeJump(calX, calY, now)) {
    relocateToNearestPunctuation(State.gazeEMA.x, State.gazeEMA.y);
  } else {
    zcut = assignLine(calX);
    const wordId = assignWord(calX);
    State.currentWordId = wordId;
    updateHighlights(wordId);
  }

  // ---- HUD ----
  hud.line.textContent = State.currentLine;
  hud.word.textContent =
    State.currentWordId != null && WORDS[State.currentWordId]
      ? `${WORDS[State.currentWordId].text} (#${State.currentWordId})`
      : "-";
  hud.raw.textContent = `${rawTrueX.toFixed(0)}, ${rawTrueY.toFixed(0)}`;
  hud.cal.textContent = `${calX.toFixed(0)}, ${calY.toFixed(0)}`;
  if (zcut) {
    hud.zcut.textContent = "YES ↩";
    hud.zcut.style.color = "#4ade80";
    setTimeout(() => {
      hud.zcut.textContent = "-";
      hud.zcut.style.color = "";
    }, 600);
  }
  if (hud.reach)
    hud.reach.textContent = `x=${State.zcutDiag.normX.toFixed(
      2
    )} max=${State.zcutDiag.reach.toFixed(2)}`;
  if (hud.zreason) hud.zreason.textContent = State.zcutDiag.reason;
  if (hud.adv) hud.adv.textContent = State.lineAdvancedBy;
  if (hud.huge)
    hud.huge.textContent = `${State.hugeDbg.dist.toFixed(
      0
    )} / ${State.hugeDbg.thresh.toFixed(0)}px (k=${JUMP_K})`;
}

/* ------------------------------------------------------------------ */
/* 9. Calibration screen (9-point grid, 5 clicks each)                */
/* ------------------------------------------------------------------ */
const calibOverlay = document.getElementById("calibOverlay");
const CLICKS_NEEDED = 5;
let calibCounts = {}; // idx -> clicks
let calibReady = false;

function buildCalibTargets() {
  calibOverlay.querySelectorAll(".calib-target").forEach((t) => t.remove());
  calibCounts = {};
  const xs = [0.1, 0.5, 0.9],
    ys = [0.12, 0.5, 0.88];
  let idx = 0;
  ys.forEach((fy) =>
    xs.forEach((fx) => {
      const t = document.createElement("div");
      t.className = "calib-target";
      t.style.left = fx * window.innerWidth + "px";
      t.style.top = fy * window.innerHeight + "px";
      t.dataset.idx = idx;
      calibCounts[idx] = 0;
      t.addEventListener("click", onCalibClick);
      calibOverlay.appendChild(t);
      idx++;
    })
  );
  updateCalibProgress();
}

function onCalibClick(e) {
  const t = e.currentTarget;
  const idx = t.dataset.idx;
  calibCounts[idx]++;
  if (window.webgazer && webgazer.recordScreenPosition) {
    webgazer.recordScreenPosition(
      parseFloat(t.style.left),
      parseFloat(t.style.top),
      "click"
    );
  }
  if (calibCounts[idx] >= CLICKS_NEEDED) t.classList.add("done");
  else t.classList.add("progress");
  updateCalibProgress();
}

function updateCalibProgress() {
  const done = Object.values(calibCounts).filter(
    (c) => c >= CLICKS_NEEDED
  ).length;
  document.getElementById(
    "calibProgress"
  ).textContent = `${done} / 9 points complete`;
  calibReady = done === 9;
  document.getElementById("btnCalibDone").disabled = !calibReady;
}

/* ------------------------------------------------------------------ */
/* 10. Accuracy check (stare at center, measure spread)               */
/*     Measures this webcam's error and noise; the noise is the sigma  */
/*     the huge-jump threshold is expressed in.                        */
/* ------------------------------------------------------------------ */
function runAccuracyCheck() {
  const accOverlay = document.getElementById("accuracyOverlay");
  const accDot = document.getElementById("accDot");
  const accResult = document.getElementById("accResult");
  const btn = document.getElementById("btnAccDone");
  accOverlay.classList.remove("hidden");
  btn.disabled = true;
  accResult.textContent = "measuring... keep staring at the dot";

  const dr = accDot.getBoundingClientRect();
  const targetX = dr.left + dr.width / 2,
    targetY = dr.top + dr.height / 2;

  const samples = [];
  const handler = (d) => {
    if (d) samples.push({ x: d.x, y: d.y });
  };
  webgazer.setGazeListener((d) => handler(d));

  setTimeout(() => {
    webgazer.setGazeListener(onGaze); // restore real listener
    if (samples.length < 5) {
      accResult.textContent =
        "No gaze samples. Check camera permission & lighting.";
    } else {
      const mean = samples.reduce((a, s) => ({ x: a.x + s.x, y: a.y + s.y }), {
        x: 0,
        y: 0,
      });
      mean.x /= samples.length;
      mean.y /= samples.length;
      const errPx = Math.hypot(mean.x - targetX, mean.y - targetY);
      // precision / NOISE: RMS spread of samples around their own mean. This is
      // the sigma the HUGE-jump threshold (JUMP_K sigmas) is measured in.
      let varSum = 0;
      samples.forEach((s) => {
        varSum += (s.x - mean.x) ** 2 + (s.y - mean.y) ** 2;
      });
      State.calibStdPx = Math.sqrt(varSum / samples.length);
      State.measuredErrPx = errPx;
      const gap = estimateLineGap();
      const verdict =
        errPx < gap
          ? "good enough for line-level ✔"
          : errPx < gap * 2
          ? "usable, expect some drift"
          : "coarse. Recalibrate or improve your lighting.";
      accResult.innerHTML = `Mean error ≈ <b>${errPx.toFixed(
        0
      )}px</b>, noise σ ≈ <b>${State.calibStdPx.toFixed(
        0
      )}px</b> (line gap ≈ ${gap.toFixed(0)}px). ${verdict}`;
    }
    btn.disabled = false;
  }, 3000);

  // Auto-start: the reader shouldn't have to find a Start button. Dismissing the
  // accuracy result drops them straight into a live tracking session.
  btn.onclick = () => {
    accOverlay.classList.add("hidden");
    State.calibrated = true;
    startTracking();
  };
}

/* ------------------------------------------------------------------ */
/* 11. Wiring: buttons, WebGazer lifecycle, toggles                   */
/* ------------------------------------------------------------------ */
let webgazerStarted = false;

async function ensureWebgazer() {
  if (webgazerStarted) return;

  webgazer
    .setRegression("ridge")
    .setGazeListener(onGaze)
    .saveDataAcrossSessions(false);

  // Apply any camera preference the user picked in Settings before the camera
  // is opened. setCameraConstraints stores the constraints on WebGazer's params,
  // which begin() then feeds straight into getUserMedia.
  if (pendingCameraConstraints) {
    try {
      await webgazer.setCameraConstraints(pendingCameraConstraints);
    } catch (e) {
      console.warn("Camera constraints rejected, falling back to default:", e);
    }
  }

  await webgazer.begin(); // starts camera + creates video/overlay elements

  setCamVisible(chkCam ? chkCam.checked : true); // respect the camera toggle
  try {
    webgazer.showPredictionPoints(false);
  } catch (e) {}
  try {
    // Off: we do our own One-Euro smoothing, which lags far less than stacking
    // WebGazer's Kalman filter on top of it. (Flip to true to compare.)
    webgazer.applyKalmanFilter(false);
  } catch (e) {}

  webgazerStarted = true;
}

/* The guided flow: welcome -> calibration -> accuracy check -> tracking.
   Both the welcome overlay's button and the top-bar Recalibrate button enter
   here, so there is exactly one path into calibration. */
async function beginCalibration() {
  setHudState("starting camera...");
  try {
    await ensureWebgazer();
  } catch (err) {
    setHudState("camera error");
    alert(
      "Could not start the webcam. Grant camera permission and use a local server (not file://).\n\n" +
        err
    );
    return;
  }
  buildCalibTargets();
  calibOverlay.classList.remove("hidden");
  setHudState("calibrating");
}

const welcomeOverlay = document.getElementById("welcomeOverlay");
document.getElementById("btnWelcomeStart").addEventListener("click", () => {
  welcomeOverlay.classList.add("hidden");
  beginCalibration();
});

document
  .getElementById("btnCalibrate")
  .addEventListener("click", beginCalibration);

document.getElementById("btnCalibDone").addEventListener("click", () => {
  if (!calibReady) return;
  calibOverlay.classList.add("hidden");
  runAccuracyCheck();
});

document.getElementById("btnCalibCancel").addEventListener("click", () => {
  calibOverlay.classList.add("hidden");
  setHudState("idle");
});

/* Start (or restart) a tracking session from the top of the passage. Calibration
   is NOT touched, so Reset is cheap: it only rewinds the reading position and
   the detectors. */
function startTracking() {
  if (!State.calibrated) return;
  buildLayout(); // ensure fresh boxes
  resetGazeFilters(); // fresh One-Euro state
  State.gazeEMA = null;
  State.tracking = true;
  State.currentLine = 0;
  State.currentWordId = null;
  State.maxOrderReached = -1;
  State.maxNormXSeen = 0;
  State.zcutFiredAt = 0;
  State.hugeJump.overMs = 0;
  State.hugeJump.lastTs = 0;
  State.hugeJump.cooldownUntil = 0;
  State.lineAdvancedBy = "-";
  // clear any highlight left over from the previous session
  WORDS.forEach((w) =>
    w.el.classList.remove("line-active", "word-active", "reloc-flash")
  );
  prevLine = -1;
  prevWord = null;
  setHudState("tracking");
}

document.getElementById("btnReset").addEventListener("click", () => {
  if (!State.calibrated) {
    // nothing to reset yet: send them through the walkthrough instead
    welcomeOverlay.classList.remove("hidden");
    return;
  }
  startTracking();
  window.scrollTo({ top: 0, behavior: "smooth" });
  setHudState("tracking (reset)");
});

// FORCED RELOCATION (paper: rare manual double-click override). Double-click a
// word to move the reading position there by hand.
passageEl.addEventListener("dblclick", (e) => {
  if (!State.tracking) return;
  const span = e.target.closest("span.w");
  if (!span) return;
  const id = parseInt(span.dataset.wid, 10);
  const w = WORDS[id];
  State.currentLine = w.lineIndex;
  State.currentWordId = id;
  State.maxNormXSeen = 0;
  // re-anchor the huge-jump detector on the new line so the manual move doesn't
  // immediately read as a deviation
  State.hugeJump.overMs = 0;
  State.hugeJump.cooldownUntil = performance.now() + HUGE_JUMP_COOLDOWN_MS;
  State.gazeEMA = { x: (w.xStart + w.xEnd) / 2, y: w.yCenter };
  if (w.orderIndex > State.maxOrderReached)
    State.maxOrderReached = w.orderIndex;
  State.lineAdvancedBy = "forced";
  updateHighlights(id);
  flashRelocation(w.el);
  setHudState("tracking (forced relocation)");
});

// toggles
document
  .getElementById("chkRawDot")
  .addEventListener("change", (e) =>
    rawDotEl.classList.toggle("hidden", !e.target.checked)
  );
document
  .getElementById("chkCalDot")
  .addEventListener("change", (e) =>
    calDotEl.classList.toggle("hidden", !e.target.checked)
  );
// show / hide the debug HUD (top-bar checkbox + the HUD's own ✕ button)
const hudEl = document.getElementById("hud");
const chkHud = document.getElementById("chkHud");
function setHudVisible(v) {
  if (hudEl) hudEl.classList.toggle("hidden", !v);
  if (chkHud) chkHud.checked = v;
}
if (chkHud)
  chkHud.addEventListener("change", (e) => setHudVisible(e.target.checked));
const btnHudClose = document.getElementById("btnHudClose");
if (btnHudClose)
  btnHudClose.addEventListener("click", () => setHudVisible(false));

// show / hide the WebGazer camera preview. The camera keeps running (tracking
// is unaffected); this only hides the video element.
function setCamVisible(v) {
  try {
    if (window.webgazer && webgazer.showVideoPreview)
      webgazer.showVideoPreview(v);
  } catch (e) {}
  const c = document.getElementById("webgazerVideoContainer");
  if (c) c.style.display = v ? "" : "none";
}
const chkCam = document.getElementById("chkCam");
if (chkCam)
  chkCam.addEventListener("change", (e) => setCamVisible(e.target.checked));

/* ------------------------------------------------------------------ */
/* 11b. Settings menu: pick which webcam WebGazer feeds from.         */
/* ------------------------------------------------------------------ */
// The constraints we'll hand to WebGazer for the next begin(). Populated by
// the Settings dropdown. If null, WebGazer uses its default (first camera).
let pendingCameraConstraints = null;
// The deviceId we last selected, so the dropdown stays in sync after a refresh.
let selectedCameraId = null;
const CAM_PREF_KEY = "wg_camera_device_id";

const settingsOverlay = document.getElementById("settingsOverlay");
const cameraSelect = document.getElementById("cameraSelect");
const cameraHint = document.getElementById("cameraHint");
const btnRefreshCameras = document.getElementById("btnRefreshCameras");
const btnSettingsClose = document.getElementById("btnSettingsClose");

// Build constraints for a specific camera. We MERGE the deviceId into WebGazer's
// own default video constraints (width/height/facingMode) instead of replacing
// them -- if we only pass {deviceId:{exact}}, the browser is free to pick any
// resolution, and many webcams will then hand WebGazer a low/default resolution
// that degrades face-detection accuracy. Keeping the resolution prefs keeps the
// tracker fed the same quality stream it expects.
function cameraConstraintsFor(deviceId) {
  if (!deviceId) return null;
  return {
    video: {
      width: { min: 320, ideal: 640, max: 1920 },
      height: { min: 240, ideal: 480, max: 1080 },
      facingMode: "user",
      deviceId: { exact: deviceId },
    },
  };
}

// Enumerate videoinput devices and fill the <select>. Labels are blank until
// the user has granted camera permission, so we surface a hint when that's the
// case (we still show the count so they know multiple cameras exist).
async function populateCameraList() {
  if (!cameraSelect) return;
  let devices = [];
  try {
    devices = await navigator.mediaDevices.enumerateDevices();
  } catch (e) {
    cameraHint.textContent =
      "Could not list cameras: " + (e.message || e) + ".";
    return;
  }
  const cams = devices.filter((d) => d.kind === "videoinput");

  // Preserve the current selection if it's still present.
  const prevValue = cameraSelect.value;
  cameraSelect.innerHTML = "";

  if (cams.length === 0) {
    const opt = document.createElement("option");
    opt.textContent = "No cameras found";
    opt.value = "";
    opt.disabled = true;
    cameraSelect.appendChild(opt);
    cameraHint.textContent =
      "No video input devices detected. Connect a webcam and click Refresh.";
    return;
  }

  const hasLabels = cams.some((c) => c.label && c.label.length > 0);
  cams.forEach((cam, i) => {
    const opt = document.createElement("option");
    opt.value = cam.deviceId;
    // Before permission is granted, labels are empty -- show a positional name
    // so the user at least sees how many cameras there are.
    opt.textContent = cam.label || "Camera " + (i + 1);
    cameraSelect.appendChild(opt);
  });

  // Restore selection: explicit prior choice > saved preference > first device.
  let targetId =
    selectedCameraId ||
    localStorage.getItem(CAM_PREF_KEY) ||
    prevValue ||
    cams[0].deviceId;
  if (!cams.some((c) => c.deviceId === targetId)) targetId = cams[0].deviceId;
  cameraSelect.value = targetId;

  if (hasLabels) {
    cameraHint.innerHTML =
      "Switching the camera invalidates calibration &mdash; recalibrate afterwards.";
  } else {
    cameraHint.textContent =
      "Camera labels are hidden until you grant camera permission. " +
      "Start calibration once, then re-open Settings to pick a specific camera.";
  }
}

// Apply the selected camera: live if WebGazer is running, otherwise stash the
// constraints for the next begin(). Persists the choice so external webcams
// stay selected across sessions.
async function applyCameraSelection(deviceId) {
  selectedCameraId = deviceId || null;
  pendingCameraConstraints = cameraConstraintsFor(deviceId);
  if (deviceId) {
    try {
      localStorage.setItem(CAM_PREF_KEY, deviceId);
    } catch (e) {}
  } else {
    try {
      localStorage.removeItem(CAM_PREF_KEY);
    } catch (e) {}
  }

  if (webgazerStarted && pendingCameraConstraints) {
    // WebGazer's setCameraConstraints swaps the live track, then resets the
    // tracker -- so the existing calibration no longer matches. Tell the user.
    try {
      await webgazer.setCameraConstraints(pendingCameraConstraints);
      setHudState("camera switched (recalibrate)");
      cameraHint.innerHTML =
        "<b>Camera switched.</b> The live track changed, so your calibration " +
        "is now stale. Click <b>Recalibrate</b> to re-train on the new camera.";
    } catch (e) {
      cameraHint.textContent =
        "Could not switch camera: " + (e.message || e) +
        ". Try closing other apps using the webcam.";
    }
  }
}

function openSettings() {
  if (!settingsOverlay) return;
  settingsOverlay.classList.remove("hidden");
  populateCameraList();
}
function closeSettings() {
  if (settingsOverlay) settingsOverlay.classList.add("hidden");
}

const btnSettings = document.getElementById("btnSettings");
if (btnSettings) btnSettings.addEventListener("click", openSettings);
if (btnSettingsClose) btnSettingsClose.addEventListener("click", closeSettings);
if (btnRefreshCameras)
  btnRefreshCameras.addEventListener("click", populateCameraList);
if (cameraSelect)
  cameraSelect.addEventListener("change", (e) =>
    applyCameraSelection(e.target.value)
  );
// Clicking the backdrop (outside the panel) closes the menu.
if (settingsOverlay)
  settingsOverlay.addEventListener("click", (e) => {
    if (e.target === settingsOverlay) closeSettings();
  });
// Hot-plugged cameras: re-populate so a newly connected webcam shows up.
if (navigator.mediaDevices && navigator.mediaDevices.ondevicechange !== undefined)
  navigator.mediaDevices.addEventListener("devicechange", () => {
    if (!settingsOverlay || !settingsOverlay.classList.contains("hidden"))
      populateCameraList();
  });

// Restore a saved camera preference on load so the external webcam is the
// default without the user having to re-open Settings every session.
(function restoreCameraPref() {
  try {
    const saved = localStorage.getItem(CAM_PREF_KEY);
    if (saved) {
      selectedCameraId = saved;
      pendingCameraConstraints = cameraConstraintsFor(saved);
    }
  } catch (e) {}
})();

// Passage font size. Bigger type = physically bigger word spans = easier gaze
// targets. Changing it reflows the text, so we rebuild the layout model and
// reset the highlight bookkeeping (the old line/word indices no longer apply).
function applyFontSize(px) {
  document.documentElement.style.setProperty("--passage-font", px + "px");
  const label = document.getElementById("fontSizeVal");
  if (label) label.textContent = px + "px";
  buildLayout(); // re-measure every word box + re-segment lines/sentences
  prevLine = -1;
  prevWord = null;
  State.currentLine = clamp(
    State.currentLine,
    0,
    Math.max(0, LINES.length - 1)
  );
  State.maxOrderReached = clamp(
    State.maxOrderReached,
    -1,
    READORDER.length - 1
  );
  if (State.tracking) updateHighlights(State.currentWordId);
}
const fontSizeInput = document.getElementById("fontSize");
if (fontSizeInput) {
  applyFontSize(parseInt(fontSizeInput.value, 10)); // sync initial value
  fontSizeInput.addEventListener("input", (e) =>
    applyFontSize(parseInt(e.target.value, 10))
  );
}

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */
function setHudState(s) {
  hud.state.textContent = s;
}
function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

// dots visible per initial checkbox state
rawDotEl.classList.remove("hidden");
calDotEl.classList.remove("hidden");

/* ------------------------------------------------------------------ */
/* init                                                              */
/* ------------------------------------------------------------------ */
function rebuild() {
  renderPassage();
  buildLayout();
}
window.addEventListener("resize", () => {
  buildLayout();
  prevLine = -1;
  prevWord = null;
});

/* Scrolling shifts the mapping between the screen (viewport) gaze and the
   document content: every gaze sample's document Y jumps by the scroll delta.
   The jump detector works in document space, so a scroll would look like a big
   sudden gaze move and fire a spurious relocation. On any scroll we re-seed the
   gaze smoother (so the EMA doesn't bridge the discontinuity) and suppress jump
   detection for a short settle window. Tracking itself is unaffected. */
window.addEventListener(
  "scroll",
  () => {
    State.gazeEMA = null; // re-seed smoothing on the next sample
    State.hugeJump.overMs = 0;
    State.hugeJump.cooldownUntil = performance.now() + HUGE_JUMP_COOLDOWN_MS;
  },
  { passive: true }
);
rebuild();
setHudState("idle, waiting for calibration");
