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
    let timestampMs: Double
}

final class ARGazeEstimator: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isRunning = false
    @Published var lastError: String? = nil
    @Published var faceVisible = false

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
        guard let (gx, gy) = Self.gazeScreenRay(faceAnchor: faceAnchor, camera: frame.camera) else {
            return
        }

        let nowMs = Self.nowMs()

        DispatchQueue.main.async {
            self.faceVisible = true
            self.onSample?(GazeSample(gx: gx, gy: gy, timestampMs: nowMs))
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.faceVisible = false }
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
