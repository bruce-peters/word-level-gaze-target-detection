// Dynamic-Y calibration: pairs each line's average raw gaze Y with that
// line's known true Y every time a Z-cut confirms the line is finished, and
// refits a rolling linear regression Y_line ~= k*Y_gaze + b. Corrects slow
// vertical drift (posture shift, head settling) with zero extra user effort.
//
// Direct port of app.js's fitRegression()/calibrateY()/finishCurrentLine()
// (see CODE_STUDY.md §4) -- left out of the initial Swift port for
// simplicity, added back per request. X is deliberately left uncorrected,
// matching the original: "X is passed through untouched -- we trust it."

import CoreGraphics

private let MAX_PAIRS = 12
private let MIN_SLOPE: CGFloat = 0.2
private let MAX_SLOPE: CGFloat = 5

final class DynamicYCalibrator {
    private(set) var k: CGFloat = 1
    private(set) var b: CGFloat = 0
    private(set) var pairs: [(rawY: CGFloat, trueY: CGFloat)] = []

    private var lineYSum: CGFloat = 0
    private var lineYCount: Int = 0

    var isFitted: Bool { pairs.count >= 2 }

    func reset() {
        k = 1
        b = 0
        pairs = []
        discardCurrentLine()
    }

    /// Record one more raw (pre-calibration) gaze Y sample for whichever
    /// line is currently being read.
    func recordSample(rawY: CGFloat) {
        lineYSum += rawY
        lineYCount += 1
    }

    /// A line finished via Z-cut: pair its average raw Y with its known true
    /// center, push into the rolling window, and refit. Resets the
    /// per-line accumulator either way.
    func finishLine(trueY: CGFloat) {
        defer { discardCurrentLine() }
        guard lineYCount > 0 else { return }
        let avgY = lineYSum / CGFloat(lineYCount)
        pairs.append((rawY: avgY, trueY: trueY))
        if pairs.count > MAX_PAIRS {
            pairs.removeFirst(pairs.count - MAX_PAIRS)
        }
        fitRegression()
    }

    /// Discards the in-progress line's accumulated samples without pairing
    /// them -- used when the line changes for a reason other than a Z-cut
    /// (huge-jump relocation, forced double-tap) so a jump-tainted average
    /// never poisons the regression.
    func discardCurrentLine() {
        lineYSum = 0
        lineYCount = 0
    }

    /// Eq.(2): Y' = k*Y + b. Passes Y through unchanged until at least two
    /// pairs have been collected.
    func calibrate(_ rawY: CGFloat) -> CGFloat {
        guard isFitted else { return rawY }
        return k * rawY + b
    }

    /// Eq.(1): OLS solve for [k,b] = argmin sum (trueY - (k*rawY + b))^2
    /// over the rolling pair window. Guards against degenerate/wild slopes
    /// by falling back to a pure offset (k = 1).
    private func fitRegression() {
        guard pairs.count >= 2 else { return }
        let n = CGFloat(pairs.count)
        let sumX = pairs.reduce(CGFloat(0)) { $0 + $1.rawY }
        let sumY = pairs.reduce(CGFloat(0)) { $0 + $1.trueY }
        let sumXY = pairs.reduce(CGFloat(0)) { $0 + $1.rawY * $1.trueY }
        let sumXX = pairs.reduce(CGFloat(0)) { $0 + $1.rawY * $1.rawY }

        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-6 else { return }

        var newK = (n * sumXY - sumX * sumY) / denom
        var newB = (sumY - newK * sumX) / n
        guard newK.isFinite, newB.isFinite else { return }

        if newK < MIN_SLOPE || newK > MAX_SLOPE {
            newK = 1
            newB = (sumY - sumX) / n
        }
        k = newK
        b = newB
    }
}
