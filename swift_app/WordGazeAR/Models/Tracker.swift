// Reading-position tracking state machine.
//
// Direct port of python_app/reading/tracker.py (itself a port of app.js
// sections 2 and 4-7): Z-cut line switching + huge-jump relocation to the
// nearest sentence start. UI-agnostic -- operates purely on point coordinates
// from a LayoutModel and exposes `processGaze(gx:gy:nowMs:fixationX:)`. Deliberately
// leaves out the paper's dynamic-Y calibration, error-vector-cloud model and
// LLM election (see CODE_STUDY.md) -- this is the "simple line tracking +
// z-jumps" subset the demo actually needs.

import CoreGraphics
import Combine
import Foundation

// "How many sigmas is HUGE": bigger = harder to trigger a relocation. Lowered
// from 4 to 1.5 to trust the eye tracker more aggressively -- relocate on a
// smaller sustained deviation instead of waiting for a very large one.
let JUMP_K: CGFloat = 1.5

// Z-cut left/right thresholds as fractions of line width. The paper uses 20%
// borders; relaxed to 30%/70% because gaze estimates compress toward center
// and often never reach the outer 20%, which would stop the Z-cut firing.
let Z_LEFT: CGFloat = 0.3
let Z_RIGHT: CGFloat = 0.7
let Z_COOLDOWN_MS: Double = 500

let HUGE_JUMP_SUSTAIN_MS: Double = 500   // deviation must hold this long to count
let HUGE_JUMP_COOLDOWN_MS: Double = 900  // settle time after a relocation (no re-trigger)
let EMA_ALPHA: CGFloat = 0.25            // gaze smoothing (lower = smoother / more lag)

// Preferred Viewing Location bias (Rayner 1979): fixations land slightly
// left of a word's true center, not at it. Used to bias word hit-testing's
// effective anchor point instead of the raw xCenter. See
// ARKIT_GAZE_RESEARCH.md.
let PVL_OFFSET_FRACTION: CGFloat = 0.4

// Linguistic-length prior weight (Rayner 1998; Kliegl et al. 2004): longer
// words draw more/longer fixations and are fixated more reliably than short
// function words, which are frequently skipped outright. Used to break ties
// near word boundaries toward the longer candidate instead of pure nearest-
// distance. 0 disables the prior (pure nearest-distance, the old
// behavior); tuned empirically once on-device -- see ARKIT_GAZE_RESEARCH.md.
let LENGTH_PRIOR_WEIGHT: CGFloat = 6

func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}

struct ZcutDiag {
    var normX: CGFloat = 0
    var reach: CGFloat = 0
    var reason: String = "-"
}

struct HugeJumpState {
    var overMs: Double = 0
    var lastTs: Double = 0
    var cooldownUntil: Double = 0
}

struct HugeDbg {
    var dist: CGFloat = 0
    var thresh: CGFloat = 0
}

enum AdvanceKind: String {
    case none = "-"
    case zcut
    case hugeJump = "huge-jump"
    case forced
}

final class TrackState: ObservableObject {
    @Published var tracking = false
    @Published var calibrated = false
    @Published var currentLine = 0
    @Published var currentWordID: Int? = nil
    var maxOrderReached = -1

    var lastNormX: CGFloat = 0.5
    var maxNormXSeen: CGFloat = 0
    var zcutFiredAt: Double = 0

    @Published var zcutDiag = ZcutDiag()
    @Published var lineAdvancedBy: AdvanceKind = .none

    var measuredErrPx: CGFloat? = nil
    var calibStdPx: CGFloat? = nil
    var gazeEMA: CGPoint? = nil
    var hugeJump = HugeJumpState()
    var hugeDbg = HugeDbg()
}

final class Tracker {
    let layout: LayoutModel
    let state = TrackState()
    private var prevLine = -1
    private var prevWord: Int? = nil
    private(set) var zcutJustFired = false

    init(layout: LayoutModel) {
        self.layout = layout
    }

    // MARK: - line assignment (Z-cut)

    /// Decide the current line during linear reading. Returns true if a
    /// Z-cut (return sweep) just fired.
    @discardableResult
    func assignLine(gx: CGFloat, nowMs: Double) -> Bool {
        let st = state
        guard layout.lines.indices.contains(st.currentLine) else { return false }
        let line = layout.lines[st.currentLine]

        let normX = clamp((gx - line.xMin) / max(1, line.width), 0, 1)
        let cooled = nowMs - st.zcutFiredAt > Z_COOLDOWN_MS

        var zcut = false
        if cooled, st.maxNormXSeen > Z_RIGHT, normX < Z_LEFT, st.currentLine < layout.lines.count - 1 {
            st.currentLine += 1
            st.maxNormXSeen = 0
            st.zcutFiredAt = nowMs
            st.lineAdvancedBy = .zcut
            zcut = true
        } else {
            st.maxNormXSeen = max(st.maxNormXSeen, normX)
        }

        recordZcutDiag(normX: normX, nowMs: nowMs)
        st.lastNormX = normX
        return zcut
    }

    private func recordZcutDiag(normX: CGFloat, nowMs: Double) {
        let st = state
        let reach = st.maxNormXSeen
        let reason: String
        if st.currentLine >= layout.lines.count - 1 {
            reason = "last line"
        } else if nowMs - st.zcutFiredAt <= Z_COOLDOWN_MS {
            reason = "cooldown"
        } else if reach <= Z_RIGHT {
            reason = String(format: "reach %.2f < %.1f, read righter", reach, Z_RIGHT)
        } else if normX >= Z_LEFT {
            reason = String(format: "armed, awaiting return (x=%.2f)", normX)
        } else {
            reason = "ready"
        }
        st.zcutDiag = ZcutDiag(normX: normX, reach: reach, reason: reason)
    }

    func estimateLineGap() -> CGFloat {
        let lines = layout.lines
        guard lines.count >= 2 else { return 60 }
        var gaps: [CGFloat] = []
        for i in 1..<lines.count {
            gaps.append(lines[i].yCenter - lines[i - 1].yCenter)
        }
        gaps.sort()
        let mid = gaps[gaps.count / 2]
        return mid > 0 ? mid : 60
    }

    // MARK: - word-within-line (best-effort)

    /// The preferred-viewing-location point for hit-testing, instead of a
    /// word's raw xCenter -- Rayner (1979): initial fixations land slightly
    /// left of a word's true center. See `PVL_OFFSET_FRACTION`.
    private func pvlPoint(_ w: Word) -> CGFloat {
        w.xStart + PVL_OFFSET_FRACTION * w.width
    }

    /// Nearest-word hit-test, scored by distance to each candidate's
    /// preferred-viewing-location point *minus* a length-based prior bonus
    /// (`LENGTH_PRIOR_WEIGHT * log(length)`) -- longer words draw more/
    /// longer fixations and are fixated more reliably than short function
    /// words (Rayner 1998; Kliegl et al. 2004), so near a word boundary the
    /// longer candidate should win a close call rather than pure nearest-
    /// distance. See ARKIT_GAZE_RESEARCH.md.
    func assignWord(gx: CGFloat) -> Int? {
        let st = state
        guard layout.lines.indices.contains(st.currentLine) else { return nil }
        let line = layout.lines[st.currentLine]
        var best: Int? = nil
        var bestScore = CGFloat.greatestFiniteMagnitude
        for wid in line.wordIDs {
            let w = layout.words[wid]
            let d = abs(gx - pvlPoint(w))
            let prior = LENGTH_PRIOR_WEIGHT * log(CGFloat(max(w.text.count, 1)))
            let score = d - prior
            if score < bestScore {
                bestScore = score
                best = wid
            }
        }
        return best
    }

    // MARK: - huge-jump relocation

    /// Where `gx`/the current line sit within the reading area, as the two
    /// fractions ErrorModel wants: 0 at either horizontal edge of the
    /// current line (1 at its center), and 0 at the top of the passage (1
    /// at the bottom). Shared by `jumpSigma` (huge-jump scale) and
    /// `fixationDispersionThreshold` (word scale) -- same position-
    /// dependent trend, two different base magnitudes.
    private func positionFractions(gx: CGFloat) -> (fromEdge: CGFloat, fromTop: CGFloat) {
        guard layout.lines.indices.contains(state.currentLine) else { return (1, 0) }
        let line = layout.lines[state.currentLine]
        let normX = clamp((gx - line.xMin) / max(1, line.width), 0, 1)
        let fractionFromEdge = 1 - 2 * abs(normX - 0.5)
        let fractionFromTop = layout.lines.count > 1
            ? CGFloat(state.currentLine) / CGFloat(layout.lines.count - 1)
            : 0
        return (fractionFromEdge, fractionFromTop)
    }

    /// Position-dependent noise floor for huge-jump detection -- see
    /// ErrorModel. Both the edge and bottom effects are independently
    /// documented as harder for ARKit/TrueDepth face tracking specifically
    /// (edges: horizontal compression; bottom: eyelid occlusion on downward
    /// gaze) -- see ARKIT_GAZE_RESEARCH.md.
    func jumpSigma(gx: CGFloat) -> CGFloat {
        let st = state
        let gap = estimateLineGap()
        let base = st.calibStdPx ?? st.measuredErrPx ?? (gap > 0 ? gap * 0.6 : 40)
        let floored = max(base, gap * 1.5)
        let (fromEdge, fromTop) = positionFractions(gx: gx)
        return ErrorModel.radius(baseSigma: floored, fractionFromEdge: fromEdge, fractionFromTop: fromTop)
    }

    /// Small-scale position-aware noise floor for FixationDetector's
    /// clustering tolerance -- as opposed to `jumpSigma`'s much larger
    /// huge-jump scale, this has no line-gap floor: a fixation should
    /// cluster at roughly word scale, not line scale.
    func fixationDispersionThreshold(gx: CGFloat) -> CGFloat {
        let base = state.calibStdPx ?? state.measuredErrPx ?? 30
        let (fromEdge, fromTop) = positionFractions(gx: gx)
        return ErrorModel.radius(baseSigma: base, fractionFromEdge: fromEdge, fractionFromTop: fromTop)
    }

    func detectHugeJump(gx: CGFloat, gy: CGFloat, nowMs: Double) -> Bool {
        let st = state
        if let ema = st.gazeEMA {
            st.gazeEMA = CGPoint(x: EMA_ALPHA * gx + (1 - EMA_ALPHA) * ema.x,
                                  y: EMA_ALPHA * gy + (1 - EMA_ALPHA) * ema.y)
        } else {
            st.gazeEMA = CGPoint(x: gx, y: gy)
        }
        guard layout.lines.indices.contains(st.currentLine) else { return false }
        let cur = layout.lines[st.currentLine]

        let thresh = JUMP_K * jumpSigma(gx: gx)
        let dist = abs((st.gazeEMA?.y ?? gy) - cur.yCenter)
        st.hugeDbg = HugeDbg(dist: dist, thresh: thresh)

        var hj = st.hugeJump
        let dt: Double = hj.lastTs > 0 ? clamp(nowMs - hj.lastTs, 0, 500) : 0
        hj.lastTs = nowMs
        defer { st.hugeJump = hj }

        if hj.cooldownUntil > 0, nowMs < hj.cooldownUntil {
            hj.overMs = 0
            return false
        }
        if dist > thresh {
            hj.overMs += dt
            if hj.overMs >= HUGE_JUMP_SUSTAIN_MS {
                return true
            }
        } else {
            hj.overMs = 0
        }
        return false
    }

    @discardableResult
    func relocateToNearestPunctuation(px: CGFloat, py: CGFloat, nowMs: Double) -> Word? {
        let st = state
        var best: Sentence? = nil
        var bestD = CGFloat.greatestFiniteMagnitude
        for s in layout.sentences {
            let w = layout.words[s.startWordID]
            let cx = (w.xStart + w.xEnd) / 2
            let dx = cx - px
            let dy = w.yCenter - py
            let d = (dx * dx + dy * dy).squareRoot()
            if d < bestD {
                bestD = d
                best = s
            }
        }
        guard let sentence = best else { return nil }
        let w = layout.words[sentence.startWordID]
        st.currentLine = w.lineIndex
        st.currentWordID = w.id
        st.maxNormXSeen = 0
        st.lineAdvancedBy = .hugeJump
        st.hugeJump.overMs = 0
        st.hugeJump.cooldownUntil = nowMs + HUGE_JUMP_COOLDOWN_MS
        st.gazeEMA = CGPoint(x: px, y: w.yCenter)
        if w.orderIndex > st.maxOrderReached { st.maxOrderReached = w.orderIndex }
        return w
    }

    /// Manual override (double-tap a word).
    @discardableResult
    func forceRelocate(wordID: Int, nowMs: Double) -> Word {
        let st = state
        let w = layout.words[wordID]
        st.currentLine = w.lineIndex
        st.currentWordID = wordID
        st.maxNormXSeen = 0
        st.hugeJump.overMs = 0
        st.hugeJump.cooldownUntil = nowMs + HUGE_JUMP_COOLDOWN_MS
        st.gazeEMA = CGPoint(x: (w.xStart + w.xEnd) / 2, y: w.yCenter)
        if w.orderIndex > st.maxOrderReached { st.maxOrderReached = w.orderIndex }
        st.lineAdvancedBy = .forced
        return w
    }

    // MARK: - highlighting bookkeeping

    /// Returns (lineChanged, wordChanged, prevLine, prevWord) and updates
    /// internal prev pointers -- mirrors app.js's module-level prevLine/prevWord
    /// diffing so the UI only touches items that actually changed.
    func lineWordChanged() -> (lineChanged: Bool, wordChanged: Bool, prevLine: Int, prevWord: Int?) {
        let st = state
        let lineChanged = st.currentLine != prevLine
        let wordChanged = st.currentWordID != prevWord
        let (pl, pw) = (prevLine, prevWord)
        if lineChanged { prevLine = st.currentLine }
        if wordChanged { prevWord = st.currentWordID }
        return (lineChanged, wordChanged, pl, pw)
    }

    // MARK: - top-level per-frame update

    /// Equivalent of the line-assignment half of app.js's onGaze(): given a
    /// filtered/predicted gaze point in layout coordinates, update tracking
    /// state. Returns true if a Z-cut fired this frame.
    ///
    /// `fixationX` is the caller's FixationDetector.currentCentroid.x (nil
    /// mid-saccade): line assignment (Z-cut/huge-jump) always uses the raw,
    /// continuous `gx` -- those mechanisms are timing-sensitive and already
    /// robust to per-sample noise -- but the final word choice only updates
    /// when a stable fixation centroid is available, holding the previous
    /// word during a saccade-in-flight rather than trusting a noisy
    /// transit sample (see FixationDetector's header + ARKIT_GAZE_RESEARCH.md).
    @discardableResult
    func processGaze(gx: CGFloat, gy: CGFloat, nowMs: Double, fixationX: CGFloat?) -> Bool {
        let st = state
        zcutJustFired = false
        if detectHugeJump(gx: gx, gy: gy, nowMs: nowMs) {
            let ema = st.gazeEMA ?? CGPoint(x: gx, y: gy)
            relocateToNearestPunctuation(px: ema.x, py: ema.y, nowMs: nowMs)
            return false
        }
        let zcut = assignLine(gx: gx, nowMs: nowMs)
        if let fx = fixationX {
            let wordID = assignWord(gx: fx)
            st.currentWordID = wordID
            if let wid = wordID, layout.words[wid].orderIndex > st.maxOrderReached {
                st.maxOrderReached = layout.words[wid].orderIndex
            }
        }
        zcutJustFired = zcut
        return zcut
    }

    // MARK: - session lifecycle

    func startTracking() {
        let st = state
        st.tracking = true
        st.currentLine = 0
        st.currentWordID = nil
        st.maxOrderReached = -1
        st.maxNormXSeen = 0
        st.zcutFiredAt = 0
        st.hugeJump = HugeJumpState()
        st.gazeEMA = nil
        st.lineAdvancedBy = .none
        prevLine = -1
        prevWord = nil
    }
}
