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
// Pipeline per frame:
//   1. worldEyeTransform = faceAnchor.transform * eyeTransform  (face-local -> world)
//   2. gaze direction (world) = average of both eyes' forward axis
//   3. rotate that direction into the camera's own frame (removes device/
//      head translation, leaves only the angle that matters)
//   4. reduce to two scalars: pitch (up/down) and yaw (left/right)
//
// pitch/yaw are exactly the feature pair gaze/calibration.py's Calibrator
// already expects, so the same 9-point linear-regression calibration
// (Calibrator.swift) maps them to screen points. Note the exact sign
// convention chosen for "forward" below is not load-bearing: a flipped axis
// just becomes a negative regression coefficient after calibration.

import ARKit
import Combine
import QuartzCore
import Foundation

struct GazeSample {
    let pitch: Double
    let yaw: Double
    let timestampMs: Double
}

final class ARGazeEstimator: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isRunning = false
    @Published var lastError: String? = nil
    @Published var latestPitch: Double = 0
    @Published var latestYaw: Double = 0
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
        guard let (pitch, yaw) = Self.gazePitchYaw(faceAnchor: faceAnchor, camera: frame.camera) else {
            return
        }

        let nowMs = Self.nowMs()

        DispatchQueue.main.async {
            self.faceVisible = true
            self.latestPitch = pitch
            self.latestYaw = yaw
            self.onSample?(GazeSample(pitch: pitch, yaw: yaw, timestampMs: nowMs))
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.faceVisible = false }
    }

    // MARK: - eye-transform math

    /// Combines both eyes' ARKit transforms into a single gaze pitch/yaw,
    /// expressed relative to the camera (i.e. the device), in radians.
    static func gazePitchYaw(faceAnchor: ARFaceAnchor, camera: ARCamera) -> (pitch: Double, yaw: Double)? {
        let leftWorld = faceAnchor.transform * faceAnchor.leftEyeTransform
        let rightWorld = faceAnchor.transform * faceAnchor.rightEyeTransform

        // Each eye transform's local -Z axis (its 3rd column, negated) is the
        // direction that eye is pointing, expressed in world space.
        let leftDir = -leftWorld.columns.2.xyz
        let rightDir = -rightWorld.columns.2.xyz
        let combined = leftDir + rightDir
        guard simd_length(combined) > 1e-6 else { return nil }
        let dirWorld = simd_normalize(combined)

        // Rotate into camera space so the angle is relative to the device,
        // not to wherever ARKit's world origin happened to start.
        let cameraInverse = camera.transform.inverse
        let dirWorld4 = SIMD4<Float>(dirWorld.x, dirWorld.y, dirWorld.z, 0)
        let dirCameraVec = (cameraInverse * dirWorld4).xyz
        guard simd_length(dirCameraVec) > 1e-6 else { return nil }
        let dirCamera = simd_normalize(dirCameraVec)

        // Camera looks down its own -Z; yaw = left/right angle, pitch = up/down.
        let yaw = Double(atan2(dirCamera.x, -dirCamera.z))
        let pitch = Double(atan2(dirCamera.y, -dirCamera.z))
        return (pitch, yaw)
    }
}

extension simd_float4 {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
