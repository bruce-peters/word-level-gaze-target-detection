// ARKit-based gaze source -- the whole point of this port.
//
// The web/python apps estimated gaze from a webcam (WebGazer ridge
// regression, or an L2CS-Net head-pose model feeding gaze/calibration.py's
// Calibrator). This estimator instead uses ARKit's TrueDepth face tracking
// and reads the *per-eye* transforms ARFaceAnchor already computes
// (`leftEyeTransform` / `rightEyeTransform`), which is a much higher-fidelity
// signal than head pose alone -- it is ARKit's own estimate of each eyeball's
// orientation, not just where the head is pointed.
//
// v2: uses eye POSITION, not just angle. An angle-only estimate (pitch/yaw
// of the gaze direction relative to the camera) cannot tell "same angle,
// head moved 5cm sideways" apart from "head still, eyes moved" -- those are
// very different screen points, but a fixed linear fit on angle alone
// conflates them, so accuracy degrades badly whenever the head moves after
// calibration. Instead, each eye's position AND direction (both relative to
// the camera) are used to intersect the gaze ray with the camera's own
// image plane (Z=0 in camera-local space -- the front TrueDepth camera sits
// essentially flush with the screen glass, so this is a good approximation
// of the screen surface). That intersection point already accounts for
// head translation geometrically; only what's left over (the small, mostly
// fixed offset between the camera and the actual visible screen rectangle)
// needs to be learned by the linear calibration on top of it.
//
// Pipeline per frame:
//   1. worldEyeTransform = faceAnchor.transform * eyeTransform  (face-local -> world)
//   2. average both eyes' position and forward direction -> world-space ray
//   3. rotate + translate that ray into the camera's own frame
//   4. intersect the ray with the camera's Z=0 plane -> (gx, gy) in meters
//
// (gx, gy) is the feature pair Calibrator does a 9-point-equivalent linear
// fit against. Note the exact sign convention chosen for "forward" is not
// load-bearing for calibration itself (a flipped axis just becomes a
// negative regression coefficient) -- but it does matter for the ray/plane
// intersection's direction of travel, so `resolveForwardSign` below
// self-corrects at runtime rather than assuming a specific ARKit axis
// convention.
//
// BASELINE SIGNAL (lax, lay): alongside the engineered ray/plane estimate
// above, every sample also carries ARKit's own `ARFaceAnchor.lookAtPoint` --
// "a position, in face coordinate space, estimating the direction of the
// face's gaze" (Apple's own description). Used directly, with no
// head-translation correction, this is the *naive* way most ARKit-gaze
// tutorials map gaze to a screen point -- exactly the "angle-only" approach
// this file's v2 header already argues is head-movement-fragile. Shipping
// it as a second feature pair lets AppModel run an independent calibration
// + accuracy measurement against it, so the "does our engineering actually
// help" question has a real on-device number behind it (see
// ARKIT_GAZE_RESEARCH.md) instead of just this file's comments asserting it.
//
// BLINK GATING: both signals are gated on the same per-frame blink check
// before either is computed, so neither pipeline sees a sample the other
// doesn't -- a fair, paired comparison. Rejecting samples during a blink is
// standard eye-tracking practice, and directly motivated here by Bignardi et
// al. (2024)'s finding that ARKit's iPad face tracking suffers "catastrophic"
// failures in some observers specifically from eyelids/eyelashes occluding
// the pupil (see ARKIT_GAZE_RESEARCH.md).

import ARKit
import Combine
import QuartzCore
import Foundation

struct GazeSample {
    /// Ray/screen-plane intersection point, in meters, in camera-local
    /// space -- NOT an angle. See file header. Small numbers (roughly
    /// -0.05...0.05) for ordinary head positions.
    let gx: Double
    let gy: Double
    /// Baseline feature pair: raw `ARFaceAnchor.lookAtPoint.x/.y`, in face
    /// coordinate space (meters, small numbers centered near 0). See file
    /// header -- this is Apple's own gaze-direction estimate, used with no
    /// head-translation correction, calibrated by its own Calibrator
    /// instance in AppModel for a head-to-head accuracy comparison.
    let lax: Double
    let lay: Double
    let timestampMs: Double
}

/// Blink amount (max of both eyes' `eyeBlinkLeft`/`eyeBlinkRight` blend
/// shapes, each 0=open...1=closed) above which a frame's gaze estimate is
/// considered unreliable and dropped rather than fed to either pipeline.
/// 0.5 is a conservative middle point: high enough that ordinary downward
/// reading gaze (partial eyelid coverage, not a full blink -- also
/// documented as an ARKit accuracy issue, see ARKIT_GAZE_RESEARCH.md) isn't
/// mistaken for a blink and needlessly discarded, low enough to catch real
/// blinks before the closing/opening eyelid corrupts the pupil-based
/// estimate.
let BLINK_THRESHOLD: Float = 0.5

final class ARGazeEstimator: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isRunning = false
    @Published var lastError: String? = nil
    @Published var faceVisible = false
    /// True on frames where a blink was detected and the sample was
    /// dropped (face is still tracked -- `faceVisible` stays true). Purely
    /// informational, surfaced on the debug HUD.
    @Published var isBlinking = false

    /// Called on the main thread for every face-tracking frame that yields a
    /// gaze estimate.
    var onSample: ((GazeSample) -> Void)?

    private let session = ARSession()

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    /// Shared clock for every "now" timestamp in the app (gaze samples and
    /// UI-driven events like forced relocation alike), so cooldowns/EMAs in
    /// Tracker never compare timestamps from two different clocks.
    static func nowMs() -> Double { CACurrentMediaTime() * 1000 }

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            lastError = "This device has no TrueDepth camera -- ARKit face tracking needs an iPhone X/iPad Pro (Face ID) or newer, on a physical device (not the Simulator)."
            return
        }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
        config.maximumNumberOfTrackedFaces = 1
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        lastError = nil
    }

    func stop() {
        session.pause()
        isRunning = false
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              faceAnchor.isTracked else {
            DispatchQueue.main.async { self.faceVisible = false }
            return
        }

        // Blink gate -- applies to BOTH signals below, so the engineered
        // and baseline pipelines always see the same set of frames (see
        // file header). Face is present and tracked, just mid-blink, so
        // faceVisible stays true; only sample emission is skipped.
        if Self.isBlinking(faceAnchor: faceAnchor) {
            DispatchQueue.main.async {
                self.faceVisible = true
                self.isBlinking = true
            }
            return
        }

        guard let (gx, gy) = Self.gazeScreenRay(faceAnchor: faceAnchor, camera: frame.camera) else {
            return
        }
        guard let (lax, lay) = Self.baselineGazePoint(faceAnchor: faceAnchor) else {
            return
        }

        let nowMs = Self.nowMs()

        DispatchQueue.main.async {
            self.faceVisible = true
            self.isBlinking = false
            self.onSample?(GazeSample(gx: gx, gy: gy, lax: lax, lay: lay, timestampMs: nowMs))
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.faceVisible = false }
    }

    // MARK: - blink gating + baseline signal

    /// True when either eye's blend-shape blink coefficient exceeds
    /// `BLINK_THRESHOLD`. Standard eye-tracking artifact rejection: a
    /// closing/opening eyelid corrupts whatever the pupil/iris-based
    /// estimate is doing underneath, for both the engineered and baseline
    /// signal alike.
    static func isBlinking(faceAnchor: ARFaceAnchor) -> Bool {
        // .floatValue (not `as? Float`) -- the reliable way to pull a
        // numeric value out of the NSNumber blendShapes stores.
        let left = faceAnchor.blendShapes[.eyeBlinkLeft]?.floatValue ?? 0
        let right = faceAnchor.blendShapes[.eyeBlinkRight]?.floatValue ?? 0
        return max(left, right) > BLINK_THRESHOLD
    }

    /// Apple's own gaze-direction estimate, used as-is (face coordinate
    /// space, no head-translation correction) as the baseline feature pair
    /// -- see file header. `lookAtPoint` is always present on a tracked
    /// face anchor (unlike the ray/plane intersection above, which can
    /// legitimately fail), so this only returns nil on a non-finite value.
    static func baselineGazePoint(faceAnchor: ARFaceAnchor) -> (lax: Double, lay: Double)? {
        let p = faceAnchor.lookAtPoint
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return (Double(p.x), Double(p.y))
    }

    // MARK: - eye-transform math

    /// Reject intersections implying a preposterous viewing distance --
    /// either a numerically unstable near-parallel ray, or a convention/
    /// tracking glitch. Ordinary phone viewing distance is ~0.25-0.6m.
    private static let minRayDistance = 0.05
    private static let maxRayDistance = 2.0

    /// Combines both eyes' ARKit transforms into a single ray/screen-plane
    /// intersection point, in meters, in camera-local space.
    static func gazeScreenRay(faceAnchor: ARFaceAnchor, camera: ARCamera) -> (gx: Double, gy: Double)? {
        let leftWorld = faceAnchor.transform * faceAnchor.leftEyeTransform
        let rightWorld = faceAnchor.transform * faceAnchor.rightEyeTransform

        // Eye position (world): each transform's translation column.
        let leftPos = leftWorld.columns.3.xyz
        let rightPos = rightWorld.columns.3.xyz
        let posWorld = (leftPos + rightPos) * 0.5

        // Eye direction (world): each transform's local -Z axis (ARKit's
        // universal "forward" convention for oriented transforms).
        let leftDir = -leftWorld.columns.2.xyz
        let rightDir = -rightWorld.columns.2.xyz
        let dirWorldSum = leftDir + rightDir
        guard simd_length(dirWorldSum) > 1e-6 else { return nil }
        let dirWorld = simd_normalize(dirWorldSum)

        // Into camera-local space: position needs the translation (w=1),
        // direction must not (w=0).
        let cameraInverse = camera.transform.inverse
        let posWorld4 = SIMD4<Float>(posWorld.x, posWorld.y, posWorld.z, 1)
        let dirWorld4 = SIMD4<Float>(dirWorld.x, dirWorld.y, dirWorld.z, 0)
        let posCamera = (cameraInverse * posWorld4).xyz
        let dirCameraRaw = simd_normalize((cameraInverse * dirWorld4).xyz)

        guard let (t, dirCamera) = resolveForwardSign(pos: posCamera, dir: dirCameraRaw) else {
            return nil
        }

        let ix = posCamera.x + t * dirCamera.x
        let iy = posCamera.y + t * dirCamera.y
        guard ix.isFinite, iy.isFinite else { return nil }
        return (gx: Double(ix), gy: Double(iy))
    }

    /// Finds the forward-in-time (t > 0) intersection of the eye ray with
    /// the camera's Z=0 plane, self-correcting the direction's sign so this
    /// doesn't depend on nailing ARKit's undocumented axis convention by
    /// hand: whichever sign of `dir` produces a positive, sane-magnitude
    /// `t` is treated as "toward the screen."
    private static func resolveForwardSign(pos: SIMD3<Float>, dir: SIMD3<Float>) -> (t: Float, dir: SIMD3<Float>)? {
        for candidate in [dir, -dir] {
            guard abs(candidate.z) > 1e-4 else { continue }
            let t = -pos.z / candidate.z
            if t > Float(minRayDistance), t < Float(maxRayDistance) {
                return (t, candidate)
            }
        }
        return nil
    }
}

extension simd_float4 {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
