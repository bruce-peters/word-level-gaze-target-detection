// Online I-DT (dispersion-threshold) fixation detector.
//
// Salvucci & Goldberg (2000), "Identifying fixations and saccades in
// eye-tracking protocols" (ETRA) -- already cited in IMPROVEMENTS.md §1 for
// the web app, never ported anywhere until now. Collapses a cluster of
// near-stationary samples into a single fixation and lets the caller ignore
// the fast-moving samples between clusters (saccades): during a saccade
// (~20-40ms) vision is suppressed, so those in-flight samples shouldn't be
// billed to whatever word they happen to sweep over. Doubly motivated here
// because Bignardi et al. (2024) found ARKit/iPad face tracking resolves
// only ~50% of reading-scale (~1.5deg) saccades that a research-grade
// tracker detects -- i.e. the raw per-sample signal *during* a saccade is
// close to noise on this hardware, so word assignment must not trust it
// (see ARKIT_GAZE_RESEARCH.md).
//
// Extends the paper's offline "emit a finished fixation" design with a
// `currentCentroid` accessor for the *in-progress* cluster: if word
// assignment only saw fixations once they closed, word highlighting would
// lag `minDurationMs` behind actual reading, which reads as broken in a
// live demo. As long as the running window's dispersion stays below
// threshold, its centroid is a good live estimate of "where the eye
// currently is, filtered of saccade noise" -- whether or not it eventually
// accumulates enough samples to count as a *reportable* fixation.

import CoreGraphics
import Foundation

struct Fixation {
    let x: CGFloat
    let y: CGFloat
    let tStart: Double
    let tEnd: Double
    let sampleCount: Int
    var duration: Double { tEnd - tStart }
}

final class FixationDetector {
    /// Minimum duration (ms) for a closed cluster to count as a genuine,
    /// reportable fixation rather than a stray sample or two -- Salvucci &
    /// Goldberg suggest ~100ms as a typical I-DT minimum; Rayner (1998)
    /// reports average reading fixations of ~200-250ms, so 100ms comfortably
    /// excludes noise without excluding real (if short) fixations. Does NOT
    /// gate `currentCentroid` -- that updates live, see file header.
    private let minDurationMs: Double

    private var window: [(x: CGFloat, y: CGFloat, t: Double)] = []

    /// The in-progress cluster's centroid, if the window currently holds a
    /// spatially-coherent run of samples (dispersion below the threshold
    /// passed to `push`) -- nil for one frame right after a dispersion
    /// break (a saccade was just detected in flight), then re-established
    /// as soon as samples start clustering again.
    private(set) var currentCentroid: CGPoint? = nil

    init(minDurationMs: Double = 100) {
        self.minDurationMs = minDurationMs
    }

    func reset() {
        window = []
        currentCentroid = nil
    }

    /// Feed one more filtered/calibrated gaze sample. `dispersionPx` is the
    /// live cluster tolerance -- callers should pass something like
    /// `ErrorModel.radius(...)` so it tracks the device/position-dependent
    /// noise floor rather than a fixed constant. Returns a finished
    /// `Fixation` the instant a dispersion break closes a cluster that met
    /// `minDurationMs`, for analytics/logging only -- live word assignment
    /// should read `currentCentroid` every frame instead of waiting for
    /// this return value.
    @discardableResult
    func push(x: CGFloat, y: CGFloat, tMs: Double, dispersionPx: CGFloat) -> Fixation? {
        window.append((x, y, tMs))

        guard windowDispersion() <= dispersionPx else {
            // Dispersion broke: the just-appended sample starts the next
            // window (possibly still mid-saccade, possibly already the
            // landing point of the next fixation -- the next call(s) will
            // tell). Close out everything before it.
            let justAppended = window.removeLast()
            let closed = window
            window = [justAppended]
            currentCentroid = nil

            guard closed.count >= 2, let first = closed.first, let last = closed.last else { return nil }
            guard last.t - first.t >= minDurationMs else { return nil }
            let n = CGFloat(closed.count)
            let cx = closed.reduce(CGFloat(0)) { $0 + $1.x } / n
            let cy = closed.reduce(CGFloat(0)) { $0 + $1.y } / n
            return Fixation(x: cx, y: cy, tStart: first.t, tEnd: last.t, sampleCount: closed.count)
        }

        let n = CGFloat(window.count)
        currentCentroid = CGPoint(
            x: window.reduce(CGFloat(0)) { $0 + $1.x } / n,
            y: window.reduce(CGFloat(0)) { $0 + $1.y } / n
        )
        return nil
    }

    private func windowDispersion() -> CGFloat {
        let xs = window.map { $0.x }
        let ys = window.map { $0.y }
        guard let xMin = xs.min(), let xMax = xs.max(), let yMin = ys.min(), let yMax = ys.max() else { return 0 }
        return (xMax - xMin) + (yMax - yMin)
    }
}
