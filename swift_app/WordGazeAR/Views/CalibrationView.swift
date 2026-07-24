// Smooth-pursuit calibration: instead of tapping and holding 9 static dots,
// a single dot glides continuously along a Lissajous-style path covering
// the screen, and every gaze sample along the way is paired with the dot's
// current (interpolated) position. This is both a nicer interaction --
// "just follow the dot with your eyes," no holding a finger down -- and
// strictly more data than 9 discrete taps: a continuous stream of samples
// over the whole path instead of a handful of clicks per point.
//
// This view only drives the dot's visuals and continuously reports its
// position via AppModel.updatePursuitTarget(_:); AppModel.beginCalibration()
// owns the actual "when is one lap done" decision via a plain timer rather
// than this view trying to detect completion itself from inside a
// per-frame TimelineView closure (that was tried first and wasn't a
// reliable way to catch a one-shot transition -- see git history).

import SwiftUI
import Foundation

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    let rootSize: CGSize

    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let t = min(elapsed / PURSUIT_DURATION, 1.0)
            let point = Self.pursuitPoint(t: t, size: rootSize)
            // `let _ =` (not a bare statement) so this side effect reliably
            // runs every frame regardless of @ViewBuilder's handling of
            // plain statements -- this is what actually keeps AppModel's
            // pursuitTargetPoint in sync with the dot; don't rely on
            // .onChange(of:) here, it isn't a dependable one-shot/edge
            // trigger inside a per-frame TimelineView closure.
            let _ = reportTarget(point)

            ZStack(alignment: .topLeading) {
                infoPanel(progress: t)
                    .position(x: rootSize.width / 2, y: min(130, rootSize.height * 0.18))

                Circle()
                    .fill(Color(red: 0.133, green: 0.773, blue: 0.369))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(point)
                    .zIndex(1)
            }
            .frame(width: rootSize.width, height: rootSize.height)
        }
        .onAppear { restart() }
    }

    private func restart() {
        startDate = Date()
        model.beginCalibration()
    }

    private func reportTarget(_ point: CGPoint) {
        guard model.calibError == nil else { return }
        model.updatePursuitTarget(point)
    }

    private func infoPanel(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibration").font(.headline).foregroundColor(.white)
            if let err = model.calibError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(Color(red: 0.97, green: 0.44, blue: 0.44))
                Button("Retry") { restart() }
                    .buttonStyle(PillButtonStyle(color: Color(red: 0.145, green: 0.388, blue: 0.922)))
            } else {
                Text("Follow the dot with just your eyes -- try to keep your head still.")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.75))
                ProgressView(value: progress)
                    .tint(Color(red: 0.133, green: 0.773, blue: 0.369))
                Button("Cancel") { model.restart() }
                    .buttonStyle(PillButtonStyle(color: Color.gray.opacity(0.35)))
            }
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color(red: 0.082, green: 0.094, blue: 0.133))
        .cornerRadius(12)
    }

    /// Lissajous curve (3:2 frequency ratio) sweeping the screen -- smooth,
    /// continuously changing direction, no sharp corners to induce
    /// saccades. `t` is a single lap in [0, 1].
    static func pursuitPoint(t: Double, size: CGSize) -> CGPoint {
        let marginX = size.width * 0.12
        let marginY = size.height * 0.16
        let cx = size.width / 2
        let cy = size.height / 2
        let ax = max(size.width / 2 - marginX, 1)
        let ay = max(size.height / 2 - marginY, 1)
        let theta = t * 2 * Double.pi
        let x = cx + ax * sin(3 * theta)
        let y = cy + ay * sin(2 * theta + .pi / 2)
        return CGPoint(x: x, y: y)
    }
}
