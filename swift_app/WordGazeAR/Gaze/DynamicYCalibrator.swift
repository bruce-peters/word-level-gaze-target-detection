// Dynamic-Y calibration: pairs each line's average raw gaze Y with that
// line's known true Y every time a Z-cut confirms the line is finished, and
// refits a rolling linear regression Y_line ~= k*Y_gaze + b (via
// RollingLinearFit). Corrects slow vertical drift (posture shift, head
// settling) with zero extra user effort.
//
// Direct port of app.js's calibrateY()/finishCurrentLine() (see
// CODE_STUDY.md §4). See DynamicXCalibrator for the horizontal counterpart.

import CoreGraphics

final class DynamicYCalibrator {
    private let fit = RollingLinearFit(maxPairs: 12)

    private var lineYSum: CGFloat = 0
    private var lineYCount: Int = 0

    var k: CGFloat { fit.k }
    var b: CGFloat { fit.b }
    var pairCount: Int { fit.pairs.count }
    var isFitted: Bool { fit.isFitted }

    func reset() {
        fit.reset()
        discardCurrentLine()
    }

    /// Record one more raw (pre-calibration) gaze Y sample for whichever
    /// line is currently being read.
    func recordSample(rawY: CGFloat) {
        lineYSum += rawY
        lineYCount += 1
    }

    /// A line finished via Z-cut: pair its average raw Y with its known true
    /// center and refit. Resets the per-line accumulator either way.
    func finishLine(trueY: CGFloat) {
        defer { discardCurrentLine() }
        guard lineYCount > 0 else { return }
        fit.addPair(raw: lineYSum / CGFloat(lineYCount), trueValue: trueY)
    }

    /// Discards the in-progress line's accumulated samples without pairing
    /// them -- used when the line changes for a reason other than a Z-cut
    /// (huge-jump relocation, forced double-tap) so a jump-tainted average
    /// never poisons the regression.
    func discardCurrentLine() {
        lineYSum = 0
        lineYCount = 0
    }

    func calibrate(_ rawY: CGFloat) -> CGFloat {
        fit.calibrate(rawY)
    }
}
