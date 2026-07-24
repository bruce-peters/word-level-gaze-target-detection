// Final calibration step: stare at a single center dot for ~3s. Mirrors
// ui/overlays.py's AccuracyOverlay / app_window.py's _run_accuracy_check --
// measures mean error (accuracy/bias) and standard deviation (precision/
// noise) of predicted gaze around the dot, and feeds the std-dev into
// Tracker.state.calibStdPx, which Tracker.jumpSigma() uses to scale the
// huge-jump threshold to this user's actual measured noise.

import SwiftUI

struct AccuracyCheckView: View {
    @ObservedObject var model: AppModel
    let rootSize: CGSize

    private var dotPoint: CGPoint {
        CGPoint(x: rootSize.width / 2, y: rootSize.height / 2)
    }

    var body: some View {
        ZStack {
            infoPanel
                .position(x: rootSize.width / 2, y: rootSize.height * 0.28)

            Circle()
                .fill(Color(red: 0.133, green: 0.773, blue: 0.369))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .position(dotPoint)
                .zIndex(1)
        }
        .frame(width: rootSize.width, height: rootSize.height)
        .onAppear {
            model.beginAccuracyCheck(dotPoint: dotPoint)
        }
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accuracy check").font(.headline).foregroundColor(.white)
            Text("Stare at the green dot below, without moving your head, until it finishes measuring.")
                .font(.caption)
                .foregroundColor(Color(white: 0.75))
            if let text = model.accuracyResultText {
                Text(text)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.9))
            }
            if model.accuracyReady {
                Button("Start reading") { model.finishAccuracyAndStartReading() }
                    .buttonStyle(PillButtonStyle(color: Color(red: 0.145, green: 0.388, blue: 0.922)))
            }
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color(red: 0.082, green: 0.094, blue: 0.133))
        .cornerRadius(12)
    }
}
