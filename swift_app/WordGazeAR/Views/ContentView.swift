// Root view: switches between welcome / calibration / reading, and hosts
// the raw + filtered gaze dots in a single shared coordinate space (named
// "root") so they line up with wherever calibration targets and the reading
// content were positioned -- see AppModel.contentOrigin for how the reading
// pass converts back out of this screen space into document space.

import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        GeometryReader { rootGeo in
            ZStack(alignment: .topLeading) {
                Color(red: 0.043, green: 0.051, blue: 0.071).ignoresSafeArea()

                switch model.phase {
                case .welcome:
                    WelcomeView(model: model)
                        .frame(width: rootGeo.size.width, height: rootGeo.size.height)
                case .calibrating:
                    CalibrationView(model: model, rootSize: rootGeo.size)
                case .accuracyCheck:
                    AccuracyCheckView(model: model, rootSize: rootGeo.size)
                case .reading:
                    ReadingView(model: model)
                }

                if model.phase == .reading || model.phase == .accuracyCheck {
                    if let raw = model.rawPoint {
                        Circle()
                            .fill(Color(red: 0.937, green: 0.267, blue: 0.267).opacity(0.85))
                            .frame(width: 12, height: 12)
                            .position(raw)
                            .allowsHitTesting(false)
                    }
                    if let filtered = model.filteredPoint {
                        Circle()
                            .fill(Color(red: 0.133, green: 0.773, blue: 0.369).opacity(0.9))
                            .frame(width: 12, height: 12)
                            .position(filtered)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onAppear {
                model.ensureLayoutBuilt(width: rootGeo.size.width)
            }
        }
        .coordinateSpace(name: "root")
        .alert("Camera / ARKit error", isPresented: Binding(
            get: { model.sourceError != nil },
            set: { shown in if !shown { model.sourceError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.sourceError ?? "")
        }
    }
}
