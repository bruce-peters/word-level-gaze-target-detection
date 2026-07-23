// One-Euro filter, ported verbatim from gaze/calibration.py (itself a port
// of app.js's OneEuro prototype + forward-prediction tunables). Adaptive
// smoothing: hard smoothing when still (kills jitter), opens up during fast
// motion (barely adds lag). One instance per axis.

import CoreGraphics
import Foundation

final class OneEuro {
    let minCutoff: Double
    let beta: Double
    let dcutoff: Double

    private var xPrev: Double? = nil
    private var dxPrev: Double = 0
    private var tPrev: Double? = nil

    init(minCutoff: Double, beta: Double, dcutoff: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dcutoff = dcutoff
    }

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    func reset() {
        xPrev = nil
        dxPrev = 0
        tPrev = nil
    }

    /// t in seconds. Returns (value, velocity_per_sec).
    func filter(_ x: Double, _ t: Double) -> (Double, Double) {
        guard let xp = xPrev, let tp = tPrev else {
            xPrev = x
            tPrev = t
            return (x, 0)
        }
        var dt = t - tp
        if !(dt > 0) { dt = 1.0 / 60 }
        tPrev = t

        let dx = (x - xp) / dt
        let aD = alpha(dcutoff, dt)
        let dxHat = aD * dx + (1 - aD) * dxPrev
        dxPrev = dxHat

        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(cutoff, dt)
        let xHat = a * x + (1 - a) * xp
        xPrev = xHat
        return (xHat, dxHat)
    }
}

// Tunables, unchanged from app.js/calibration.py. beta must stay SMALL for
// noisy gaze: cutoff = min_cutoff + beta*|velocity|, and an inflated
// velocity estimate from noise would blow the cutoff open and turn off
// smoothing.
let FILTER_MIN_CUTOFF = 0.6   // Hz
let FILTER_BETA = 0.006
let FILTER_DCUTOFF = 0.4      // Hz
let LEAD_MS: Double = 25      // forward prediction to compensate pipeline latency
let PREDICT_CLAMP_PX: Double = 35  // hard clamp so a noisy velocity spike can't fling the dot

/// Pairs one OneEuro per axis with the forward-prediction step from
/// app.js's onGaze().
final class GazeFilter {
    private let oeX = OneEuro(minCutoff: FILTER_MIN_CUTOFF, beta: FILTER_BETA, dcutoff: FILTER_DCUTOFF)
    private let oeY = OneEuro(minCutoff: FILTER_MIN_CUTOFF, beta: FILTER_BETA, dcutoff: FILTER_DCUTOFF)

    func reset() {
        oeX.reset()
        oeY.reset()
    }

    func filter(x: Double, y: Double, tSec: Double) -> CGPoint {
        let (sx, vx) = oeX.filter(x, tSec)
        let (sy, vy) = oeY.filter(y, tSec)
        let lead = LEAD_MS / 1000.0
        let predX = clamp(vx * lead, -PREDICT_CLAMP_PX, PREDICT_CLAMP_PX)
        let predY = clamp(vy * lead, -PREDICT_CLAMP_PX, PREDICT_CLAMP_PX)
        return CGPoint(x: sx + predX, y: sy + predY)
    }
}
