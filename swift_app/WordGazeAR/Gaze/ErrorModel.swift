// Position-dependent gaze-error radius model.
//
// Ports RT2H's errorRange()/errorRangeY() (web app only, app.js -- see
// CODE_STUDY.md §5, [DEVIATION]-tagged there as "reproduces the reported
// *trend*... not the exact surface") to Swift, where it never existed. Two
// independent sources agree on the *shape* of this trend, not just the
// original webcam paper:
//   - RT2H itself (16-user webcam study): error is worse near the left/right
//     borders and concentrates toward the bottom of the screen.
//   - Bignardi et al. (2024), "(The limits of) eye-tracking with iPads":
//     independently finds the SAME two effects on ARKit/iPad face tracking
//     specifically -- horizontal saccade amplitude is underestimated near
//     screen edges ("eye-trackers commonly lose view of the pupil when the
//     eye rotates too far to the right or left"), and accuracy is worse
//     toward the bottom of the screen (eyelids partially covering the pupil
//     on downward gaze).
// See ARKIT_GAZE_RESEARCH.md for both citations in full.
//
// Reading naturally spends a lot of time exactly where this is worst: every
// line sweeps to both horizontal edges, and later lines sit lower on the
// screen. Feeding this into Tracker's huge-jump threshold makes the jump
// detector *more* forgiving exactly where the hardware is documented to be
// noisier (fewer false-positive relocations at edges / late in a passage)
// and *tighter* in the reliable center, instead of one flat sigma
// everywhere.

import CoreGraphics

enum ErrorModel {
    /// Extra radius, as a fraction of `baseSigma`, added at the horizontal
    /// extremes of the reading area. Same magnitude as RT2H's app.js
    /// `errorRange()` boost, kept consistent across the project.
    static let edgeBoost: CGFloat = 0.6
    /// Extra radius fraction added toward the bottom of the reading area.
    static let bottomBoost: CGFloat = 0.3

    /// - Parameters:
    ///   - baseSigma: the device/user's measured noise floor (e.g.
    ///     `Tracker.state.calibStdPx`).
    ///   - fractionFromEdge: 0 at either horizontal edge of the current
    ///     line, 1 at its horizontal center.
    ///   - fractionFromTop: 0 at the top of the passage, 1 at the bottom.
    static func radius(baseSigma: CGFloat, fractionFromEdge: CGFloat, fractionFromTop: CGFloat) -> CGFloat {
        let edgeFactor = 1 + edgeBoost * (1 - clamp(fractionFromEdge, 0, 1))
        let bottomFactor = 1 + bottomBoost * clamp(fractionFromTop, 0, 1)
        return baseSigma * edgeFactor * bottomFactor
    }
}
