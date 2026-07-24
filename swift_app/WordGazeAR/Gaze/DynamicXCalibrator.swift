// Dynamic-X calibration: the horizontal counterpart to DynamicYCalibrator,
// and the highest-value follow-up IMPROVING_LINE_JUMPS.md flagged and never
// built ("§6 recommended next steps, item C -- dynamic-X calibration...
// highest-value follow-up").
//
// Unlike Y (roughly constant while reading one line, so a single per-line
// average is the right signal), X sweeps across almost the whole line width
// while reading it -- so instead of one pair per line, this tracks the
// raw-X *extremes* reached while reading a line (leftmost/rightmost gaze
// X), and on Z-cut pairs those against the line's true xMin/xMax. Two pairs
// per line, same rolling-OLS core (RollingLinearFit) as Y.
//
// Payoff is bigger than it looks: raw X feeds both the Z-cut's normX
// (IMPROVING_LINE_JUMPS.md's core failure mode -- gaze rarely reaching the
// true right edge, so the Z-cut never arms) *and* word-within-line
// assignment, so correcting X's compression toward center should make both
// more reliable over the course of a session, not just line-jumps.

import CoreGraphics

final class DynamicXCalibrator {
    private let fit = RollingLinearFit(maxPairs: 16)

    private var lineMinX: CGFloat? = nil
    private var lineMaxX: CGFloat? = nil

    var k: CGFloat { fit.k }
    var b: CGFloat { fit.b }
    var pairCount: Int { fit.pairs.count }
    var isFitted: Bool { fit.isFitted }

    func reset() {
        fit.reset()
        discardCurrentLine()
    }

    /// Record one more raw (pre-calibration) gaze X sample for whichever
    /// line is currently being read, widening that line's seen range.
    func recordSample(rawX: CGFloat) {
        lineMinX = min(lineMinX ?? rawX, rawX)
        lineMaxX = max(lineMaxX ?? rawX, rawX)
    }

    /// A line finished via Z-cut: pair its raw-X extremes with the line's
    /// known true left/right edges and refit. Resets the per-line
    /// accumulator either way.
    func finishLine(trueXMin: CGFloat, trueXMax: CGFloat) {
        defer { discardCurrentLine() }
        guard let minX = lineMinX, let maxX = lineMaxX, maxX > minX else { return }
        fit.addPair(raw: minX, trueValue: trueXMin)
        fit.addPair(raw: maxX, trueValue: trueXMax)
    }

    /// Discards the in-progress line's accumulated range without pairing it
    /// -- used when the line changes for a reason other than a Z-cut
    /// (huge-jump relocation, forced double-tap).
    func discardCurrentLine() {
        lineMinX = nil
        lineMaxX = nil
    }

    func calibrate(_ rawX: CGFloat) -> CGFloat {
        fit.calibrate(rawX)
    }
}
