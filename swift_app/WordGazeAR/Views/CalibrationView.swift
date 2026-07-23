// 9-point tap calibration, mirroring ui/overlays.py's CalibrationOverlay:
// hold each dot while looking at it, ARGazeEstimator's pitch/yaw samples
// collected during the hold are paired with that dot's screen point and fed
// to Calibrator (many samples per dot, vs. the Tk app's 5 discrete clicks).

import SwiftUI

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    let rootSize: CGSize

    private let cols = CALIB_TARGET_XF
    private let rows = CALIB_TARGET_YF

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<(cols.count * rows.count), id: \.self) { idx in
                let pt = targetPoint(idx)
                CalibDot(done: model.calibDoneIndices.contains(idx),
                         active: model.calibActiveIndex == idx)
                    .position(pt)
                    .onLongPressGesture(minimumDuration: 0.9, maximumDistance: 60, pressing: { pressing in
                        if pressing {
                            model.beginCapture(pointIndex: idx, at: pt)
                        } else {
                            model.endCapture()
                        }
                    }, perform: {
                        model.markPointDone(idx)
                    })
            }

            infoPanel
                .position(x: rootSize.width / 2, y: min(120, rootSize.height * 0.16))
        }
        .frame(width: rootSize.width, height: rootSize.height)
    }

    private func targetPoint(_ idx: Int) -> CGPoint {
        let col = idx % cols.count
        let row = idx / cols.count
        return CGPoint(x: cols[col] * rootSize.width, y: rows[row] * rootSize.height)
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calibration").font(.headline).foregroundColor(.white)
            Text("Hold your finger on each dot for about a second while looking straight at it.")
                .font(.caption)
                .foregroundColor(Color(white: 0.75))
            Text("\(model.calibDoneIndices.count) / \(cols.count * rows.count) points complete")
                .font(.caption).bold()
                .foregroundColor(Color(red: 0.58, green: 0.77, blue: 0.99))
            if let err = model.calibError {
                Text(err).font(.caption).foregroundColor(Color(red: 0.97, green: 0.44, blue: 0.44))
            }
            HStack(spacing: 8) {
                Button("Finish calibration") { model.finishCalibration() }
                    .disabled(!model.calibrationComplete)
                    .buttonStyle(PillButtonStyle(color: model.calibrationComplete
                        ? Color(red: 0.145, green: 0.388, blue: 0.922)
                        : Color.gray.opacity(0.4)))
                Button("Cancel") { model.restart() }
                    .buttonStyle(PillButtonStyle(color: Color.gray.opacity(0.35)))
            }
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color(red: 0.082, green: 0.094, blue: 0.133))
        .cornerRadius(12)
    }
}

private struct CalibDot: View {
    let done: Bool
    let active: Bool

    var body: some View {
        Circle()
            .fill(done
                ? Color(red: 0.133, green: 0.773, blue: 0.369)
                : (active ? Color(red: 0.961, green: 0.62, blue: 0.043) : Color(red: 0.937, green: 0.267, blue: 0.267)))
            .frame(width: 26, height: 26)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .scaleEffect(active ? 1.25 : 1.0)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

struct PillButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption).bold()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}
