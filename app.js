/* ============================================================================
   Gaze Reader — an explainable re-implementation of RT²H
   ----------------------------------------------------------------------------
   Paper: "See Where You Read with Eye Gaze Tracking and Large Language Model"
          Sikai Yang, Gang Yan, Wan Du (arXiv:2409.19454). Internally the paper
          calls the system RT²H (Reading Tracking + Real-Time Highlighting).

   GOAL OF THIS FILE
     Track *where in the text the user is reading* from a plain laptop webcam,
     and highlight it, so a reader never loses their place. The hard part is that
     webcam gaze error (~2 cm) is far larger than a line of text (~4–5 mm), so we
     cannot trust a raw gaze point to hit a line, let alone a word. RT²H closes
     that gap with FOUR ideas, all implemented here:

       (1) LINEAR READING TRACKING  — while reading a line normally, horizontal
           gaze x is a reliable "progress along the line" signal because a line
           is much wider than the gaze error. A right→left return sweep (a
           "Z-cut") means "go to the next line".            → assignLine()

       (2) DYNAMIC-Y CALIBRATION   — after each finished line we pair its average
           raw gaze Y with the line's known Y and fit a rolling linear regression
           trueY ≈ k·rawY + b, correcting slow vertical drift with no user
           effort.                                          → fitRegression()

       (3) TWO GAZE ERROR MODELS   — (a) an error-RANGE model that says how far
           off gaze can be at a given screen location (bigger near borders /
           bottom), used to decide when the reader has left the current line; and
           (b) an error-VECTOR-cloud model (a 2-D Gaussian of 500 sample offsets)
           used to score which sentence a messy jump trajectory was aiming at.
                                                            → §5 Error models

       (4) JUMP READING + LLM ELECTION — when the reader jumps away from linear
           order, we detect it (2.5 s of active gaze off the current line),
           collect candidate destinations (sentence starts near the gaze), score
           each candidate with the error cloud (a "match ratio"), keep the top
           three, and let an LLM pick the most plausible next sentence from
           reading context (+0.1 bonus). The winner becomes the new position.
                                                            → §8–§10

   SCALE / UNITS NOTE (a deliberate deviation, see CODE_STUDY.md):
     The paper measures everything in centimetres on a known physical display.
     A web page only knows CSS pixels, so we convert with PX_PER_CM and, when the
     accuracy check has run, rescale the error model to *this* webcam's measured
     error. Every such deviation is called out in comments tagged  [DEVIATION].
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

// layout model — rebuilt on load and on resize
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
   FIRST word is the candidate a jump can land on; its bounding box (union of its
   word boxes) is the region the error cloud is tested against. */
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
  maxOrderReached: -1, // furthest reading-order index ever reached (read trail)

  // dynamic-Y regression: trueY ≈ k*rawY + b
  reg: { k: 1, b: 0 },
  yPairs: [], // rolling [{rawY, trueY}]
  MAX_PAIRS: 12,

  // per-line raw-Y accumulation (for the dynamic calibration pairing)
  lineYSamples: [],

  // Z-cut bookkeeping
  lastNormX: 0.5, // last horizontal position as fraction of line width
  maxNormXSeen: 0, // how far right we've read on the current line
  zcutFiredAt: 0,

  // (E) diagnostics: why has / hasn't the Z-cut fired, and how did we last advance
  zcutDiag: { normX: 0, reach: 0, reason: "—" },
  lineAdvancedBy: "—", // "zcut" | "y-adv" | "jump" | "forced" | "—"

  // (B) conservative adjacent-line Y advance bookkeeping
  yAdvanceAt: 0,

  // dwell log: wid -> ms
  dwell: {},
  lastTickTs: 0,

  // ---- jump reading (§8) ----
  jump: {
    outsideMs: 0, // accumulated ACTIVE time spent off the current line
    trajectory: [], // [{x,y}] calibrated gaze doc-coords during a suspected jump
    lastTs: 0,
    relocating: false, // guard while async LLM election is in flight
  },
  lastCandidateCount: 0,
  lastLLMPick: "—",

  // measured webcam accuracy (px), from the accuracy check; scales error model
  measuredErrPx: null,

  // LLM
  llmKey: "",

  // toggles
  // --- MODE ---
  // lineLock: the ONLY way to leave a line is a detected Z-cut (return sweep).
  // Y is ignored for line assignment, so gaze wandering can't jump lines. All
  // the "fancy" mechanisms below are off by default.
  lineLock: true,

  useDynY: false, // dynamic-Y remap (not used while line-locked)
  showHeat: false, // dwell heatmap
  useJump: false, // jump reading + LLM relocation (advanced mode only)
  showTrail: false, // read-trail highlight

  // --- HUGE-jump relocation (works WITH line-lock) ---
  // Assume the reader is in the normal flow almost always; only relocate on a
  // deviation bigger than k × (calibration noise). Then snap to the nearest
  // punctuation (sentence start).
  useHugeJump: true,
  jumpK: 4, // "how many sigmas is HUGE" — bigger = harder to trigger (matches the #jumpK input default)
  calibStdPx: null, // precision (noise std) measured during the accuracy check
  gazeEMA: null, // smoothed gaze {x,y} — noise rejection before the outlier test
  hugeJump: { overMs: 0, lastTs: 0 }, // sustain timer so one spike can't trigger
  hugeDbg: { dist: 0, thresh: 0 }, // for the HUD
};

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
  reg: document.getElementById("hudReg"),
  pairs: document.getElementById("hudPairs"),
  jump: document.getElementById("hudJump"),
  err: document.getElementById("hudErr"),
  cand: document.getElementById("hudCand"),
  llm: document.getElementById("hudLLM"),
  reach: document.getElementById("hudReach"),
  zreason: document.getElementById("hudZReason"),
  adv: document.getElementById("hudAdv"),
  huge: document.getElementById("hudHuge"),
};

/* ------------------------------------------------------------------ */
/* 4. Dynamic-Y calibration: fit rolling linear regression (paper §5) */
/*    Eq.(1)  [k,b] = argmin Σ (Y_line − (k·Y_gaze + b))²             */
/*    Eq.(2)  [X',Y'] ← [X, k·Y + b]                                  */
/* ------------------------------------------------------------------ */
function fitRegression() {
  const pts = State.yPairs;
  if (pts.length < 2) {
    State.reg = { k: 1, b: 0 };
    return;
  }
  // ordinary least squares on (rawY -> trueY)  == Eq.(1)
  let sx = 0,
    sy = 0,
    sxx = 0,
    sxy = 0;
  const n = pts.length;
  pts.forEach((p) => {
    sx += p.rawY;
    sy += p.trueY;
    sxx += p.rawY * p.rawY;
    sxy += p.rawY * p.trueY;
  });
  const denom = n * sxx - sx * sx;
  if (Math.abs(denom) < 1e-6) {
    State.reg = { k: 1, b: 0 };
    return;
  }
  let k = (n * sxy - sx * sy) / denom;
  let b = (sy - k * sx) / n;
  // guard against a wild slope when the data is degenerate
  if (!isFinite(k) || k < 0.2 || k > 5) {
    k = 1;
    b = pts[pts.length - 1].trueY - pts[pts.length - 1].rawY;
  }
  State.reg = { k, b };
}

function calibrateY(rawY) {
  if (!State.useDynY) return rawY;
  return State.reg.k * rawY + State.reg.b; // Eq.(2), Y only
}

/* ------------------------------------------------------------------ */
/* 5. Gaze error models (paper §4)                                    */
/*    Two empirical models learned from 16 users. We cannot ship their */
/*    raw dataset, so we reproduce the reported *statistics* and shape  */
/*    and (when available) rescale to THIS webcam's measured error.     */
/*    [DEVIATION] see CODE_STUDY.md "Error models".                     */
/* ------------------------------------------------------------------ */

// CSS reference: 1 inch = 96px = 2.54cm  ⇒  ~37.8 px/cm.  [DEVIATION: assumed]
const PX_PER_CM = 96 / 2.54;

// Paper's reported error statistics (centimetres).
const ERR_CM = {
  AVG: 1.9455, // §4 error-range model, overall mean error
  SIGMA_X: 1.8471, // §4 error-vector model, horizontal std dev
  SIGMA_Y: 1.2289, // §4 error-vector model, vertical std dev
};

// Working values in px. baseAvgPx is what we scale everything to; it starts from
// the paper (cm→px) and is overwritten by the accuracy check when we know the
// real error for this camera/user.
const ERR = {
  baseAvgPx: ERR_CM.AVG * PX_PER_CM,
  get sigmaX() {
    return ERR_CM.SIGMA_X * PX_PER_CM * this._scale;
  },
  get sigmaY() {
    return ERR_CM.SIGMA_Y * PX_PER_CM * this._scale;
  },
  _scale: 1, // multiplier so measured error can grow/shrink the paper model
};

// Rescale the whole error model to the accuracy check's measured mean error.
function calibrateErrorModel(measuredErrPx) {
  State.measuredErrPx = measuredErrPx;
  ERR._scale = measuredErrPx / ERR.baseAvgPx; // keep paper's x/y anisotropy
  buildErrorCloud(); // cloud depends on sigmaX/sigmaY
}

/* -- Error-RANGE model --------------------------------------------------------
   Returns the plausible gaze error *radius* (px) at a screen location. The paper
   found error grows near the borders (esp. left/right) and toward the bottom, so
   we scale a base radius by proximity to those edges. Used to (a) decide when
   gaze has genuinely LEFT the current line, and (b) bound the search for jump
   candidates.  [DEVIATION]: qualitative shape only, not the raw 16-user map. */
function errorRange(xDoc, yDoc) {
  const vx = xDoc - window.scrollX; // to viewport for edge-distance
  const vy = yDoc - window.scrollY;
  const W = window.innerWidth,
    H = window.innerHeight;
  const fromSide = Math.min(vx, W - vx) / (W / 2); // 0 at an edge, 1 at center
  const fromBottom = (H - vy) / H; // 0 at bottom, 1 at top
  // up to +60% near L/R edges, +30% near the bottom edge
  const sideBoost = 1 + 0.6 * (1 - clamp(fromSide, 0, 1));
  const bottomBoost = 1 + 0.3 * (1 - clamp(fromBottom, 0, 1));
  return ERR.baseAvgPx * ERR._scale * sideBoost * bottomBoost;
}

// Vertical half-height of the current-line error band (how far off in Y a gaze
// can be and still plausibly be on this line). Drives jump *escape* detection.
function errorRangeY(xDoc, yDoc) {
  return errorRange(xDoc, yDoc) * (ERR_CM.SIGMA_Y / ERR_CM.AVG); // scale to Y std
}

/* -- Error-VECTOR-cloud model -------------------------------------------------
   A fixed set of 500 offset vectors drawn from a 2-D Gaussian with the paper's
   anisotropic std devs (σx≈1.85cm, σy≈1.23cm). "Attaching the cloud" to a gaze
   point p yields 500 hypotheses of where the user was really looking. Used by
   the match-ratio scorer.  Paper: "500 randomly sampled vectors ... for
   computational efficiency." */
const CLOUD_N = 500;
let ERROR_CLOUD = []; // [{dx,dy}] px offsets

function buildErrorCloud() {
  ERROR_CLOUD = new Array(CLOUD_N);
  for (let i = 0; i < CLOUD_N; i++) {
    ERROR_CLOUD[i] = {
      dx: gaussian() * ERR.sigmaX,
      dy: gaussian() * ERR.sigmaY,
    };
  }
}

// Standard-normal sample via Box–Muller.
function gaussian() {
  let u = 0,
    v = 0;
  while (u === 0) u = Math.random();
  while (v === 0) v = Math.random();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

/* ------------------------------------------------------------------ */
/* 6. Linear reading: line assignment (Z-cut) (paper §5)              */
/* ------------------------------------------------------------------ */
// thresholds as fractions of line width. Paper uses 20% borders; we relax to
// 30%/70% because webcam gaze compresses toward center and often never reaches
// the outer 20%, which would stop the Z-cut from ever firing.
const Z_LEFT = 0.3; // "left region" = leftmost 30%
const Z_RIGHT = 0.7; // "right region" = rightmost 30%
const Z_COOLDOWN_MS = 500;

/* Given the calibrated gaze point, decide the current line during LINEAR reading.
     1. horizontal progress normX along the CURRENT line (x is trustworthy).
     2. Z-cut: read into the right region, then snap back to left ⇒ next line.
     3. Fallback (only when jump-reading is OFF): if calibrated Y is wildly off
        the current line, snap to nearest line by Y.
   Returns true if a Z-cut just fired (for HUD). */
function assignLine(gx, gy) {
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
    finishCurrentLine(); // pair avg rawY with this line's trueY (dynamic calib)
    State.currentLine++;
    State.maxNormXSeen = 0;
    State.zcutFiredAt = now;
    State.lineAdvancedBy = "zcut";
    zcut = true;
  } else {
    State.maxNormXSeen = Math.max(State.maxNormXSeen, normX);
  }

  // (E) record WHY the Z-cut did / didn't fire, for the HUD
  recordZcutDiag(normX, now);

  // (B) Conservative adjacent-line Y advance — OFF while line-locked. Only runs
  // in the advanced mode (jump reading on, lock off).
  if (!zcut && !State.lineLock && State.useJump)
    advanceLineByY(gx, gy, normX, now);

  // ---- Legacy global nearest-Y fallback (advanced mode only, lock off) ----
  if (!State.lineLock && !State.useJump) {
    const gap = estimateLineGap();
    const cur = LINES[State.currentLine];
    if (cur && Math.abs(gy - cur.yCenter) > gap * 1.3) {
      let best = State.currentLine,
        bestD = Infinity;
      LINES.forEach((L) => {
        const d = Math.abs(gy - L.yCenter);
        if (d < bestD) {
          bestD = d;
          best = L.lineIndex;
        }
      });
      if (best !== State.currentLine) {
        State.currentLine = best;
        State.maxNormXSeen = normX;
        State.lineAdvancedBy = "nearest-Y";
      }
    }
  }

  State.lastNormX = normX;
  return zcut;
}

/* (E) Explain the Z-cut state so it's visible in the HUD. The classic stuck
   case is "reach 0.68 < 0.80": horizontal gaze compresses toward center and
   never touches the right region, so the return sweep can never arm. */
function recordZcutDiag(normX, now) {
  const reach = State.maxNormXSeen;
  let reason;
  if (State.currentLine >= LINES.length - 1) reason = "last line";
  else if (now - State.zcutFiredAt <= Z_COOLDOWN_MS) reason = "cooldown";
  else if (reach <= Z_RIGHT)
    reason = `reach ${reach.toFixed(2)} < ${Z_RIGHT} — read righter`;
  else if (normX >= Z_LEFT)
    reason = `armed — awaiting return (x=${normX.toFixed(2)})`;
  else reason = "ready";
  State.zcutDiag = { normX, reach, reason };
}

/* (B) Adjacent-line Y advance.
   Reading normally makes calibrated Y drift down monotonically. When Y has
   clearly crossed toward the *adjacent* line's center (more than
   Y_ADVANCE_FRACTION of a line gap, but less than Y_ADVANCE_MAX gaps — beyond
   that it's a genuine jump, which we leave to the jump-reading relocation), we
   step exactly one line in that direction. Downward steps also feed the dynamic
   calibration via finishCurrentLine(), so the regression keeps updating even
   when the Z-cut never fires. */
const Y_ADVANCE_FRACTION = 0.6; // fraction of a line gap that counts as "moved"
const Y_ADVANCE_MAX = 1.6; // gaps; beyond this it's a jump, not a line advance
const Y_ADVANCE_COOLDOWN_MS = 400;
function advanceLineByY(gx, gy, normX, now) {
  if (now - State.yAdvanceAt < Y_ADVANCE_COOLDOWN_MS) return;
  const cur = LINES[State.currentLine];
  if (!cur) return;
  const gap = estimateLineGap();
  const delta = gy - cur.yCenter;
  const mag = Math.abs(delta);
  if (mag < Y_ADVANCE_FRACTION * gap) return; // not clearly off the current line
  if (mag > Y_ADVANCE_MAX * gap) return; // too far — that's a jump, not a step

  const dir = delta > 0 ? 1 : -1;
  const target = State.currentLine + dir;
  if (target < 0 || target > LINES.length - 1) return;
  // sanity: the target line must genuinely be closer to the gaze than current
  if (Math.abs(gy - LINES[target].yCenter) >= mag) return;

  if (dir > 0) {
    finishCurrentLine(); // leaving this line downward → pair its Y for calibration
  } else {
    State.lineYSamples = []; // upward re-read: don't poison the pairing
  }
  State.currentLine = target;
  State.maxNormXSeen = normX; // fresh horizontal reach on the new line
  State.yAdvanceAt = now;
  State.lineAdvancedBy = "y-adv";
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

/* When a line is finished (Z-cut), pair its average RAW Y with the line's TRUE
   yCenter and refit the regression. This is the dynamic-Y calibration (paper:
   "domain-specific line-gaze alignment for dynamic calibration"). */
function finishCurrentLine() {
  if (State.lineYSamples.length >= 3) {
    const avgRaw =
      State.lineYSamples.reduce((a, b) => a + b, 0) / State.lineYSamples.length;
    const trueY = LINES[State.currentLine].yCenter;
    State.yPairs.push({ rawY: avgRaw, trueY });
    if (State.yPairs.length > State.MAX_PAIRS) State.yPairs.shift();
    fitRegression();
  }
  State.lineYSamples = [];
}

/* ------------------------------------------------------------------ */
/* 7. Word-within-line (best-effort)                                  */
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
/* 8. Jump reading detection (paper §6)                               */
/* ------------------------------------------------------------------ */
const JUMP_TIME_MS = 2500; // paper: "2.5 seconds of accumulative active gazing"

// Is the reader engaged with the text (vs. looking away)? Paper: idle gaze does
// not accumulate toward the jump threshold. We approximate "engaged" as "gaze
// falls inside the reading area". [DEVIATION]: paper also uses head/eye idle
// cues we don't have from WebGazer's point stream.
function isActiveGaze(xDoc, yDoc) {
  const r = passageEl.getBoundingClientRect();
  const x = xDoc - window.scrollX,
    y = yDoc - window.scrollY;
  const pad = 60;
  return (
    x >= r.left - pad &&
    x <= r.right + pad &&
    y >= r.top - pad &&
    y <= r.bottom + pad
  );
}

/* Per-sample jump bookkeeping. Called from the gaze loop while tracking.
   Returns "jump" if the accumulated off-line time crossed the threshold (the
   caller then runs relocation), else "linear" (keep reading normally). */
function updateJump(gx, gy, ts) {
  const j = State.jump;
  const dt = j.lastTs ? clamp(ts - j.lastTs, 0, 500) : 0;
  j.lastTs = ts;
  if (j.relocating) return "linear"; // frozen during LLM election

  const cur = LINES[State.currentLine];
  if (!cur) return "linear";

  const active = isActiveGaze(gx, gy);
  const offLine = Math.abs(gy - cur.yCenter) > errorRangeY(gx, gy);

  if (active && offLine) {
    // gaze has genuinely left the current line and the user is engaged
    j.outsideMs += dt;
    j.trajectory.push({ x: gx, y: gy });
    if (j.trajectory.length > 400) j.trajectory.shift();
    if (j.outsideMs >= JUMP_TIME_MS) return "jump";
  } else if (!offLine) {
    // back on the current line ⇒ this was not a jump; reset the accumulator
    j.outsideMs = 0;
    j.trajectory.length = 0;
  }
  // active-but-off yet under threshold, or idle: hold state, keep accumulating
  return "linear";
}

/* ------------------------------------------------------------------ */
/* 8b. HUGE-jump relocation (noise-robust, works WITH line-lock)       */
/*     Assume the reader stays in the current flow almost always. Only  */
/*     relocate on a deviation larger than  k × (calibration noise),    */
/*     measured on a SMOOTHED gaze and required to persist briefly so a  */
/*     single noisy webcam sample can never trigger it. On trigger, snap */
/*     to the nearest punctuation (sentence start) to the gaze.          */
/* ------------------------------------------------------------------ */
const HUGE_JUMP_SUSTAIN_MS = 500; // deviation must hold this long to count
const HUGE_JUMP_COOLDOWN_MS = 900; // settle time after a relocation (no re-trigger)
const EMA_ALPHA = 0.25; // gaze smoothing (lower = smoother / more lag)

// The noise scale the "huge" threshold is measured in: the standard deviation /
// error recorded during calibration, with a small floor and sane fallbacks.
function jumpSigma() {
  const s =
    State.calibStdPx || State.measuredErrPx || estimateLineGap() * 0.6 || 40;
  return Math.max(s, 12);
}

// Smooth the gaze, then test how far it is (vertically, from the current line)
// relative to k·sigma. Returns true once the deviation has persisted long
// enough. Always call it (it also maintains the EMA + timer).
function detectHugeJump(gx, gy, now) {
  if (!State.gazeEMA) State.gazeEMA = { x: gx, y: gy };
  else {
    State.gazeEMA.x = EMA_ALPHA * gx + (1 - EMA_ALPHA) * State.gazeEMA.x;
    State.gazeEMA.y = EMA_ALPHA * gy + (1 - EMA_ALPHA) * State.gazeEMA.y;
  }
  const cur = LINES[State.currentLine];
  if (!cur) return false;

  const thresh = State.jumpK * jumpSigma();
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
  State.lineYSamples = [];
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
/* 9. Jump relocation: candidates + match ratio + LLM election (§6–7) */
/*    (advanced mode only — line-lock uses the HUGE-jump path above)   */
/* ------------------------------------------------------------------ */

// A cloud sample point landing "on" a sentence = inside any of its word boxes
// (small pad). Fast-rejected by the sentence bbox first.
const HIT_PAD = 4;
function pointInSentence(px, py, s) {
  if (
    px < s.xMin - HIT_PAD ||
    px > s.xMax + HIT_PAD ||
    py < s.yMin - 22 ||
    py > s.yMax + 22
  )
    return false;
  for (const id of s.wordIds) {
    const w = WORDS[id];
    if (
      px >= w.xStart - HIT_PAD &&
      px <= w.xEnd + HIT_PAD &&
      py >= w.yCenter - 22 &&
      py <= w.yCenter + 22
    )
      return true;
  }
  return false;
}

/* MATCH RATIO (paper §6.2): for every gaze point on the jump trajectory, attach
   the 500-sample error cloud and count what fraction of samples land on the
   candidate sentence; average over the trajectory. High ⇒ the messy gaze cloud
   is consistent with the reader having been aiming at that sentence. Baseline
   winners in the paper sit around ~0.3. */
function matchRatio(sentence, traj) {
  if (!traj.length) return 0;
  // subsample the trajectory to <=40 anchor points to keep this ~O(20k) checks
  const step = Math.max(1, Math.floor(traj.length / 40));
  let hits = 0,
    anchors = 0;
  for (let i = 0; i < traj.length; i += step) {
    anchors++;
    const p = traj[i];
    for (let c = 0; c < ERROR_CLOUD.length; c++) {
      const o = ERROR_CLOUD[c];
      if (pointInSentence(p.x + o.dx, p.y + o.dy, sentence)) hits++;
    }
  }
  return hits / (anchors * ERROR_CLOUD.length);
}

// Candidate destinations = sentence starts within the error range of where the
// gaze settled (last trajectory points). Paper: "search for punctuation marks
// within error range as potential destinations."
function findCandidates(traj) {
  const tail = traj.slice(-8);
  const land = tail.reduce(
    (a, p) => ({ x: a.x + p.x / tail.length, y: a.y + p.y / tail.length }),
    { x: 0, y: 0 }
  );
  let radius = errorRange(land.x, land.y);
  for (let tries = 0; tries < 4; tries++) {
    const cands = SENTENCES.filter((s) => {
      const w = WORDS[s.startWordId];
      const cx = (w.xStart + w.xEnd) / 2;
      return Math.hypot(cx - land.x, w.yCenter - land.y) <= radius;
    });
    if (cands.length) return { cands, land };
    radius *= 1.8; // widen if we caught nothing
  }
  // last resort: nearest sentence start to the landing point
  let best = SENTENCES[0],
    bestD = Infinity;
  SENTENCES.forEach((s) => {
    const w = WORDS[s.startWordId];
    const d = Math.hypot((w.xStart + w.xEnd) / 2 - land.x, w.yCenter - land.y);
    if (d < bestD) {
      bestD = d;
      best = s;
    }
  });
  return { cands: [best], land };
}

/* The full relocation pipeline (async because of the LLM call). */
async function relocate() {
  const j = State.jump;
  j.relocating = true;
  setHudState("jump — relocating…");

  const traj = j.trajectory.slice();
  const { cands } = findCandidates(traj);

  // score every candidate by match ratio
  const scored = cands
    .map((s) => ({ s, score: matchRatio(s, traj) }))
    .sort((a, b) => b.score - a.score);

  const top3 = scored.slice(0, 3);
  State.lastCandidateCount = cands.length;

  // LLM election (paper §7): if there is ambiguity, ask an LLM which sentence is
  // most likely read next, and give that one a +0.1 bonus. With a single
  // candidate the paper skips the model entirely.
  let winner = top3[0];
  State.lastLLMPick = "—";
  if (top3.length > 1) {
    const pickIdx = await electWithLLM(top3);
    if (pickIdx >= 0 && top3[pickIdx]) {
      top3[pickIdx].score += 0.1; // paper's bonus
      State.lastLLMPick = shortText(top3[pickIdx].s);
    }
    winner = top3.reduce((a, b) => (b.score > a.score ? b : a), top3[0]);
  }

  applyRelocation(winner.s);

  // reset jump accumulation and resume linear reading from the new spot
  j.outsideMs = 0;
  j.trajectory.length = 0;
  j.relocating = false;
  setHudState("tracking");
}

// Move the reading position to a sentence start and flash it.
function applyRelocation(sentence) {
  const w = WORDS[sentence.startWordId];
  State.currentLine = w.lineIndex;
  State.currentWordId = w.id;
  State.maxNormXSeen = 0;
  State.lineYSamples = [];
  if (w.orderIndex > State.maxOrderReached)
    State.maxOrderReached = w.orderIndex;
  State.lineAdvancedBy = "jump";
  updateHighlights(w.id);
  flashRelocation(w.el);
}

/* ------------------------------------------------------------------ */
/* 10. LLM election (paper §7 — GPT-4o mini via OpenAI)               */
/* ------------------------------------------------------------------ */
// Returns the index (into `top3`) the model chose, or -1 to skip the bonus.
// [DEVIATION]: browser apps can't hide an API key, so the call is OPTIONAL and
// gated on a user-supplied key; with no key we degrade gracefully (no bonus),
// which the paper never has to do.
async function electWithLLM(top3) {
  if (!State.llmKey) return -1;
  const material = readingHistoryText();
  const options = top3
    .map((c, i) => `${i + 1}. ${shortText(c.s, 120)}`)
    .join("\n");
  // Paper's prompt shape:
  //   "The user was just reading: <<<Reading Material>>>, which option is most
  //    likely to be read next by the user?"
  const prompt =
    `The user was just reading:\n<<<${material}>>>\n\n` +
    `Which option is most likely to be read next by the user? ` +
    `Reply with ONLY the option number.\n${options}`;
  try {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + State.llmKey,
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        temperature: 0,
        max_tokens: 4,
        messages: [{ role: "user", content: prompt }],
      }),
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const data = await res.json();
    const txt = (data.choices?.[0]?.message?.content || "").trim();
    const m = txt.match(/\d+/);
    if (!m) return -1;
    const idx = parseInt(m[0], 10) - 1;
    return idx >= 0 && idx < top3.length ? idx : -1;
  } catch (e) {
    console.warn("[LLM] election skipped:", e.message);
    return -1;
  }
}

// The text the reader has covered so far (reading history before the jump),
// used as the LLM's context.
function readingHistoryText() {
  const upto = Math.max(State.maxOrderReached, 0);
  const ids = READORDER.slice(0, upto + 1);
  const txt = ids.map((id) => WORDS[id].text).join(" ");
  return txt.length > 1200 ? txt.slice(-1200) : txt; // keep the prompt small
}

function shortText(sentence, max = 60) {
  const t = sentence.wordIds.map((id) => WORDS[id].text).join(" ");
  return t.length > max ? t.slice(0, max) + "…" : t;
}

/* ------------------------------------------------------------------ */
/* 11. Highlighting + read-trail + dwell + heatmap                    */
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
    paintReadTrail();
  }
}

/* The core UX of "See Where You Read": everything up to the furthest point the
   reader has reached is tinted, so on any line jump the reader can instantly see
   what they've already covered. */
function paintReadTrail() {
  for (let oi = 0; oi <= State.maxOrderReached; oi++) {
    const w = WORDS[READORDER[oi]];
    if (!w) continue;
    if (State.showTrail) w.el.classList.add("read-trail");
    else w.el.classList.remove("read-trail");
  }
}

function tickDwell(wordId, ts) {
  if (State.lastTickTs && wordId != null) {
    const dt = ts - State.lastTickTs;
    if (dt > 0 && dt < 500) {
      State.dwell[wordId] = (State.dwell[wordId] || 0) + dt;
    }
  }
  State.lastTickTs = ts;
}

// paint a warmth heatmap from dwell times (cheap proxy for "lingered here")
function paintHeatmap() {
  if (!State.showHeat) return;
  let max = 0;
  for (const k in State.dwell) max = Math.max(max, State.dwell[k]);
  if (max <= 0) return;
  for (const k in State.dwell) {
    const t = State.dwell[k] / max; // 0..1
    const w = WORDS[k];
    if (!w) continue;
    if (w.el.classList.contains("word-active")) continue;
    w.el.style.backgroundColor =
      t > 0.02
        ? `rgba(255,${Math.round(160 - 120 * t)},60,${(0.1 + 0.5 * t).toFixed(
            3
          )})`
        : "";
  }
}

function renderDwellList() {
  const top = Object.entries(State.dwell)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 8);
  const ol = document.getElementById("dwellList");
  ol.innerHTML = top
    .map(
      ([id, ms]) =>
        `<li>${escapeHtml(WORDS[id] ? WORDS[id].text : id)} — ${Math.round(
          ms
        )}</li>`
    )
    .join("");
}

// brief blue pulse when a relocation moves the reading position
function flashRelocation(el) {
  el.classList.add("reloc-flash");
  setTimeout(() => el.classList.remove("reloc-flash"), 900);
}

/* ------------------------------------------------------------------ */
/* 12. WebGazer gaze listener — the main loop                         */
/* ------------------------------------------------------------------ */
function onGaze(data, ts) {
  if (!data) return;
  // WebGazer gives VIEWPORT coords; our layout model is in DOCUMENT coords.
  const rawX = data.x + window.scrollX;
  const rawY = data.y + window.scrollY;

  // draw raw dot (dots are position:fixed -> use viewport coords)
  rawDotEl.style.left = data.x + "px";
  rawDotEl.style.top = data.y + "px";

  if (!State.tracking) return;

  // calibrated Y (X we trust as-is: line width >> horizontal error)
  const calY = calibrateY(rawY);
  const calX = rawX;

  calDotEl.style.left = calX - window.scrollX + "px";
  calDotEl.style.top = calY - window.scrollY + "px";

  // collect per-line raw-Y samples for dynamic calibration pairing
  State.lineYSamples.push(rawY);

  const now = ts || performance.now();

  // ---- line assignment ----
  let zcut = false;
  if (State.lineLock) {
    // SIMPLE robust flow: line stays locked; the only ways off it are a Z-cut
    // (return sweep to the next line) or a HUGE jump (relocate to nearest
    // punctuation). Everything is driven by X + the huge-jump outlier test.
    if (State.useHugeJump && detectHugeJump(calX, calY, now)) {
      relocateToNearestPunctuation(State.gazeEMA.x, State.gazeEMA.y);
    } else {
      zcut = assignLine(calX, calY);
      const wordId = assignWord(calX);
      State.currentWordId = wordId;
      updateHighlights(wordId);
      tickDwell(wordId, now);
    }
  } else {
    // ADVANCED pipeline: jump reading + error-cloud + LLM election.
    let mode = "linear";
    if (State.useJump) mode = updateJump(calX, calY, now);
    if (mode === "jump") {
      relocate(); // async; freezes jump state until it resolves
    } else if (!State.jump.relocating) {
      zcut = assignLine(calX, calY);
      const wordId = assignWord(calX);
      State.currentWordId = wordId;
      updateHighlights(wordId);
      tickDwell(wordId, now);
    }
  }

  // ---- HUD ----
  hud.line.textContent = State.currentLine;
  hud.word.textContent =
    State.currentWordId != null && WORDS[State.currentWordId]
      ? `${WORDS[State.currentWordId].text} (#${State.currentWordId})`
      : "—";
  hud.raw.textContent = `${rawX.toFixed(0)}, ${rawY.toFixed(0)}`;
  hud.cal.textContent = `${calX.toFixed(0)}, ${calY.toFixed(0)}`;
  if (zcut) {
    hud.zcut.textContent = "YES ↩";
    hud.zcut.style.color = "#4ade80";
    setTimeout(() => {
      hud.zcut.textContent = "—";
      hud.zcut.style.color = "";
    }, 600);
  }
  hud.reg.textContent = `k=${State.reg.k.toFixed(3)}, b=${State.reg.b.toFixed(
    1
  )}`;
  hud.pairs.textContent = State.yPairs.length;
  if (hud.jump)
    hud.jump.textContent = State.jump.relocating
      ? "relocating…"
      : `${(State.jump.outsideMs / 1000).toFixed(1)}s / 2.5s`;
  if (hud.err) hud.err.textContent = `${errorRange(calX, calY).toFixed(0)}px`;
  if (hud.cand) hud.cand.textContent = State.lastCandidateCount;
  if (hud.llm) hud.llm.textContent = State.lastLLMPick;
  if (hud.reach)
    hud.reach.textContent = `x=${State.zcutDiag.normX.toFixed(
      2
    )} max=${State.zcutDiag.reach.toFixed(2)}`;
  if (hud.zreason) hud.zreason.textContent = State.zcutDiag.reason;
  if (hud.adv) hud.adv.textContent = State.lineAdvancedBy;
  if (hud.huge)
    hud.huge.textContent = State.useHugeJump
      ? `${State.hugeDbg.dist.toFixed(0)} / ${State.hugeDbg.thresh.toFixed(
          0
        )}px (k=${State.jumpK})`
      : "off";
}

/* A lightweight periodic repaint for the heatmap / dwell list. */
setInterval(() => {
  if (State.tracking) {
    paintHeatmap();
    renderDwellList();
  }
}, 600);

/* ------------------------------------------------------------------ */
/* 13. Calibration screen (9-point grid, 5 clicks each)               */
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
/* 14. Accuracy check (stare at center, measure spread)               */
/*     Also rescales the error model to this webcam's measured error.  */
/* ------------------------------------------------------------------ */
function runAccuracyCheck() {
  const accOverlay = document.getElementById("accuracyOverlay");
  const accDot = document.getElementById("accDot");
  const accResult = document.getElementById("accResult");
  const btn = document.getElementById("btnAccDone");
  accOverlay.classList.remove("hidden");
  btn.disabled = true;
  accResult.textContent = "measuring… keep staring at the dot";

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
        "No gaze samples — check camera permission & lighting.";
    } else {
      const mean = samples.reduce((a, s) => ({ x: a.x + s.x, y: a.y + s.y }), {
        x: 0,
        y: 0,
      });
      mean.x /= samples.length;
      mean.y /= samples.length;
      const errPx = Math.hypot(mean.x - targetX, mean.y - targetY);
      // precision / NOISE: RMS spread of samples around their own mean. This is
      // the sigma the HUGE-jump threshold (k·sigma) is measured in.
      let varSum = 0;
      samples.forEach((s) => {
        varSum += (s.x - mean.x) ** 2 + (s.y - mean.y) ** 2;
      });
      State.calibStdPx = Math.sqrt(varSum / samples.length);
      calibrateErrorModel(errPx); // <-- feed real error into the error models
      const gap = estimateLineGap();
      const verdict =
        errPx < gap
          ? "good enough for line-level ✔"
          : errPx < gap * 2
          ? "usable — expect some drift"
          : "coarse — recalibrate / improve lighting";
      accResult.innerHTML = `Mean error ≈ <b>${errPx.toFixed(
        0
      )}px</b>, noise σ ≈ <b>${State.calibStdPx.toFixed(
        0
      )}px</b> (line gap ≈ ${gap.toFixed(0)}px). HUGE-jump threshold ≈ ${(
        State.jumpK * jumpSigma()
      ).toFixed(0)}px. ${verdict}`;
    }
    btn.disabled = false;
  }, 3000);

  btn.onclick = () => {
    accOverlay.classList.add("hidden");
    State.calibrated = true;
    document.getElementById("btnStart").disabled = false;
    setHudState("calibrated — press Start");
  };
}

/* ------------------------------------------------------------------ */
/* 15. Wiring: buttons, WebGazer lifecycle, toggles                   */
/* ------------------------------------------------------------------ */
let webgazerStarted = false;

async function ensureWebgazer() {
  if (webgazerStarted) return;

  webgazer
    .setRegression("ridge")
    .setGazeListener(onGaze)
    .saveDataAcrossSessions(false);

  await webgazer.begin(); // starts camera + creates video/overlay elements

  setCamVisible(chkCam ? chkCam.checked : true); // respect the camera toggle
  try {
    webgazer.showPredictionPoints(false);
  } catch (e) {}
  try {
    webgazer.applyKalmanFilter(true);
  } catch (e) {}

  webgazerStarted = true;
}

document.getElementById("btnCalibrate").addEventListener("click", async () => {
  setHudState("starting camera…");
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
});

document.getElementById("btnCalibDone").addEventListener("click", () => {
  if (!calibReady) return;
  calibOverlay.classList.add("hidden");
  runAccuracyCheck();
});

document.getElementById("btnCalibCancel").addEventListener("click", () => {
  calibOverlay.classList.add("hidden");
  setHudState("idle");
});

document.getElementById("btnStart").addEventListener("click", () => {
  if (!State.calibrated) return;
  buildLayout(); // ensure fresh boxes
  buildErrorCloud(); // (re)build the 500-sample cloud at current scale
  State.tracking = true;
  State.currentLine = 0;
  State.currentWordId = null;
  State.maxOrderReached = -1;
  State.maxNormXSeen = 0;
  State.lastTickTs = 0;
  State.jump.outsideMs = 0;
  State.jump.trajectory.length = 0;
  State.jump.lastTs = 0;
  document.getElementById("btnStart").disabled = true;
  document.getElementById("btnStop").disabled = false;
  setHudState("tracking");
});

document.getElementById("btnStop").addEventListener("click", () => {
  State.tracking = false;
  document.getElementById("btnStart").disabled = false;
  document.getElementById("btnStop").disabled = true;
  setHudState("stopped");
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
  State.lineYSamples = [];
  State.jump.outsideMs = 0;
  State.jump.trajectory.length = 0;
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
document.getElementById("chkDynY").addEventListener("change", (e) => {
  State.useDynY = e.target.checked;
  setHudState(State.tracking ? "tracking" : "idle");
});
document.getElementById("chkHeat").addEventListener("change", (e) => {
  State.showHeat = e.target.checked;
  if (!e.target.checked) {
    WORDS.forEach((w) => {
      w.el.style.backgroundColor = "";
    });
  }
});
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
// is unaffected) — this only hides the video element.
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

const chkLineLock = document.getElementById("chkLineLock");
if (chkLineLock)
  chkLineLock.addEventListener("change", (e) => {
    State.lineLock = e.target.checked;
    setHudState(State.tracking ? "tracking" : "idle");
  });
const chkHugeJump = document.getElementById("chkHugeJump");
if (chkHugeJump)
  chkHugeJump.addEventListener("change", (e) => {
    State.useHugeJump = e.target.checked;
    State.hugeJump.overMs = 0;
  });
const jumpKInput = document.getElementById("jumpK");
if (jumpKInput) {
  // sync State to the input's actual value on load (the HTML default is the
  // source of truth; don't rely on the State literal staying in sync by hand).
  const initK = parseFloat(jumpKInput.value);
  if (isFinite(initK) && initK > 0) State.jumpK = initK;
  jumpKInput.addEventListener("change", (e) => {
    const v = parseFloat(e.target.value);
    if (isFinite(v) && v > 0) State.jumpK = v;
  });
}
const chkJump = document.getElementById("chkJump");
if (chkJump)
  chkJump.addEventListener("change", (e) => {
    State.useJump = e.target.checked;
  });
const chkTrail = document.getElementById("chkTrail");
if (chkTrail)
  chkTrail.addEventListener("change", (e) => {
    State.showTrail = e.target.checked;
    paintReadTrail();
  });
// Passage font size. Bigger type = physically bigger word spans = easier gaze
// targets. Changing it reflows the text, so we rebuild the layout model and
// reset the highlight bookkeeping (the old line/word indices no longer apply).
function applyFontSize(px) {
  document.documentElement.style.setProperty("--passage-font", px + "px");
  const label = document.getElementById("fontSizeVal");
  if (label) label.textContent = px + "px";
  buildLayout(); // re-measure every word box + re-segment lines/sentences
  buildErrorCloud(); // scale-independent, but cheap and keeps things consistent
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
  if (State.tracking) {
    updateHighlights(State.currentWordId);
    paintReadTrail();
  }
}
const fontSizeInput = document.getElementById("fontSize");
if (fontSizeInput) {
  applyFontSize(parseInt(fontSizeInput.value, 10)); // sync initial value
  fontSizeInput.addEventListener("input", (e) =>
    applyFontSize(parseInt(e.target.value, 10))
  );
}

const llmKeyInput = document.getElementById("llmKey");
if (llmKeyInput)
  llmKeyInput.addEventListener("change", (e) => {
    State.llmKey = e.target.value.trim();
  });

// export dwell log
document.getElementById("btnDump").addEventListener("click", () => {
  const out = {
    exportedAt: new Date().toISOString(),
    regression: State.reg,
    yPairs: State.yPairs,
    errorModel: {
      scale: ERR._scale,
      sigmaXpx: ERR.sigmaX,
      sigmaYpx: ERR.sigmaY,
      measuredErrPx: State.measuredErrPx,
    },
    words: Object.entries(State.dwell)
      .map(([id, ms]) => ({
        id: +id,
        text: WORDS[id] ? WORDS[id].text : null,
        lineIndex: WORDS[id] ? WORDS[id].lineIndex : null,
        dwellMs: Math.round(ms),
      }))
      .sort((a, b) => b.dwellMs - a.dwellMs),
  };
  console.log("=== DWELL LOG ===", out);
  const blob = new Blob([JSON.stringify(out, null, 2)], {
    type: "application/json",
  });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "dwell-log.json";
  a.click();
  URL.revokeObjectURL(a.href);
});

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */
function setHudState(s) {
  hud.state.textContent = s;
}
function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}
function escapeHtml(s) {
  return String(s).replace(
    /[&<>]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c])
  );
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
   The jump detectors work in document space, so a scroll would look like a big
   sudden gaze move and fire a spurious relocation. On any scroll we re-seed the
   gaze smoother (so the EMA doesn't bridge the discontinuity) and suppress jump
   detection for a short settle window. Tracking itself is unaffected. */
window.addEventListener(
  "scroll",
  () => {
    State.gazeEMA = null; // re-seed smoothing on the next sample
    State.hugeJump.overMs = 0;
    State.hugeJump.cooldownUntil = performance.now() + HUGE_JUMP_COOLDOWN_MS;
    State.jump.outsideMs = 0; // advanced-mode trajectory detector too
    State.jump.trajectory.length = 0;
  },
  { passive: true }
);
rebuild();
buildErrorCloud();
setHudState("idle — press Calibrate");
