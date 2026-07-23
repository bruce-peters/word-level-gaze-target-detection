// Fits screenX ~= a*pitch + b*yaw + c and screenY ~= d*pitch + e*yaw + f
// from 9-point tap calibration data, exactly mirroring gaze/calibration.py's
// Calibrator (which itself replaced WebGazer's internal ridge regression
// after switching to a head-pose-relative feature pair). Here the features
// are pitch/yaw of the gaze direction derived from ARKit's per-eye
// transforms (see ARGazeEstimator) rather than a pose-estimation model, but
// the fit -- and therefore the rest of the pipeline -- is identical: any
// fixed sign/axis convention in how pitch/yaw were derived is just another
// linear term the regression absorbs.

import simd
import CoreGraphics

final class Calibrator {
    private(set) var samples: [(pitch: Double, yaw: Double, x: Double, y: Double)] = []
    private var coefX: SIMD3<Double>? = nil  // (a, b, c)
    private var coefY: SIMD3<Double>? = nil  // (d, e, f)

    var isFitted: Bool { coefX != nil && coefY != nil }

    func addSample(pitch: Double, yaw: Double, screenX: Double, screenY: Double) {
        samples.append((pitch, yaw, screenX, screenY))
    }

    func clear() {
        samples = []
        coefX = nil
        coefY = nil
    }

    enum FitError: Error { case notEnoughSamples, singularSystem }

    /// Ordinary least squares via the normal equations: solve (AᵀA) c = Aᵀb
    /// for each of screenX and screenY, sharing the same AᵀA. A's rows are
    /// [pitch, yaw, 1].
    func fit() throws {
        guard samples.count >= 6 else { throw FitError.notEnoughSamples }

        var ata = double3x3(diagonal: .zero)
        var atbX = SIMD3<Double>.zero
        var atbY = SIMD3<Double>.zero

        for s in samples {
            let row = SIMD3<Double>(s.pitch, s.yaw, 1)
            ata += outer(row, row)
            atbX += row * s.x
            atbY += row * s.y
        }

        let det = ata.determinant
        guard abs(det) > 1e-9 else { throw FitError.singularSystem }
        let inv = ata.inverse
        coefX = inv * atbX
        coefY = inv * atbY
    }

    func predict(pitch: Double, yaw: Double) -> CGPoint? {
        guard let cx = coefX, let cy = coefY else { return nil }
        let row = SIMD3<Double>(pitch, yaw, 1)
        return CGPoint(x: dot(cx, row), y: dot(cy, row))
    }
}

private func outer(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> double3x3 {
    double3x3(columns: (a * b.x, a * b.y, a * b.z))
}
