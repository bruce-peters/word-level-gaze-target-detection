// Shared core behind both dynamic-axis calibrators (DynamicYCalibrator,
// DynamicXCalibrator): a rolling OLS fit v' = k*v + b over the last
// `maxPairs` (raw, true) pairs, with a slope clamp/fallback so a couple of
// noisy pairs can't wreck the fit. Direct port of app.js's fitRegression()
// (CODE_STUDY.md §4), generalized so it isn't Y-specific -- the two
// calibrators differ only in *what* they pair and *when*, not in the fit
// itself.

import CoreGraphics

final class RollingLinearFit {
    private(set) var k: CGFloat = 1
    private(set) var b: CGFloat = 0
    private(set) var pairs: [(raw: CGFloat, trueValue: CGFloat)] = []

    private let maxPairs: Int
    private let minSlope: CGFloat
    private let maxSlope: CGFloat

    var isFitted: Bool { pairs.count >= 2 }

    init(maxPairs: Int, minSlope: CGFloat = 0.2, maxSlope: CGFloat = 5) {
        self.maxPairs = maxPairs
        self.minSlope = minSlope
        self.maxSlope = maxSlope
    }

    func reset() {
        k = 1
        b = 0
        pairs = []
    }

    /// Pushes a new (raw, trueValue) pair into the rolling window and
    /// refits.
    func addPair(raw: CGFloat, trueValue: CGFloat) {
        pairs.append((raw, trueValue))
        if pairs.count > maxPairs {
            pairs.removeFirst(pairs.count - maxPairs)
        }
        fit()
    }

    /// v' = k*v + b. Passes v through unchanged until at least two pairs
    /// have been collected.
    func calibrate(_ raw: CGFloat) -> CGFloat {
        guard isFitted else { return raw }
        return k * raw + b
    }

    /// OLS solve for [k,b] = argmin sum (trueValue - (k*raw + b))^2 over the
    /// rolling pair window. Guards against degenerate/wild slopes by
    /// falling back to a pure offset (k = 1).
    private func fit() {
        guard pairs.count >= 2 else { return }
        let n = CGFloat(pairs.count)
        let sumX = pairs.reduce(CGFloat(0)) { $0 + $1.raw }
        let sumY = pairs.reduce(CGFloat(0)) { $0 + $1.trueValue }
        let sumXY = pairs.reduce(CGFloat(0)) { $0 + $1.raw * $1.trueValue }
        let sumXX = pairs.reduce(CGFloat(0)) { $0 + $1.raw * $1.raw }

        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-6 else { return }

        var newK = (n * sumXY - sumX * sumY) / denom
        var newB = (sumY - newK * sumX) / n
        guard newK.isFinite, newB.isFinite else { return }

        if newK < minSlope || newK > maxSlope {
            newK = 1
            newB = (sumY - sumX) / n
        }
        k = newK
        b = newB
    }
}
