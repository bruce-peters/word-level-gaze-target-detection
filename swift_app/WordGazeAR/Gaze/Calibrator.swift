// Fits screenX ~= a*gx + b*gy + c and screenY ~= d*gx + e*gy + f from
// pursuit-calibration samples, exactly mirroring gaze/calibration.py's
// Calibrator (which itself replaced WebGazer's internal ridge regression
// after switching to a head-pose-relative feature pair). The features here
// are (gx, gy) -- ARKit's eye-ray/screen-plane intersection point in meters
// (see ARGazeEstimator), already translation-aware, so this fit only has to
// learn the small residual offset/scale between the camera's own image
// plane and the actual visible screen rectangle. It's deliberately generic
// on the feature names: any two roughly-linear predictors of screen
// position would work here.

import simd
import CoreGraphics

final class Calibrator {
    private(set) var samples: [(gx: Double, gy: Double, x: Double, y: Double)] = []
    private var coefX: SIMD3<Double>? = nil  // (a, b, c)
    private var coefY: SIMD3<Double>? = nil  // (d, e, f)

    var isFitted: Bool { coefX != nil && coefY != nil }

    func addSample(gx: Double, gy: Double, screenX: Double, screenY: Double) {
        samples.append((gx, gy, screenX, screenY))
    }

    func clear() {
        samples = []
        coefX = nil
        coefY = nil
    }

    enum FitError: Error { case notEnoughSamples, singularSystem }

    /// Ordinary least squares via the normal equations: solve (AᵀA) c = Aᵀb
    /// for each of screenX and screenY, sharing the same AᵀA. A's rows are
    /// [gx, gy, 1].
    func fit() throws {
        guard samples.count >= 6 else { throw FitError.notEnoughSamples }

        var ata = double3x3(diagonal: .zero)
        var atbX = SIMD3<Double>.zero
        var atbY = SIMD3<Double>.zero

        for s in samples {
            let row = SIMD3<Double>(s.gx, s.gy, 1)
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

    func predict(gx: Double, gy: Double) -> CGPoint? {
        guard let cx = coefX, let cy = coefY else { return nil }
        let row = SIMD3<Double>(gx, gy, 1)
        return CGPoint(x: dot(cx, row), y: dot(cy, row))
    }
}

private func outer(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> double3x3 {
    double3x3(columns: (a * b.x, a * b.y, a * b.z))
}
