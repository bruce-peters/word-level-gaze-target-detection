// Settings sheet -- currently just font size, mirroring ui/app_window.py's
// top-bar font slider (24-140px there; narrower range here since phone
// screens are smaller and word-level gaze precision wants a large font).

import SwiftUI
import Foundation

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var layout: LayoutModel
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        self.layout = model.layout
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text("\(Int(layout.font.pointSize))pt")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(layout.font.pointSize) },
                            set: { model.setFontSize(CGFloat($0)) }
                        ),
                        in: Double(LayoutModel.minFontSize)...Double(LayoutModel.maxFontSize),
                        step: 1
                    )
                } header: {
                    Text("Passage")
                } footer: {
                    Text("A larger font makes individual words easier to fixate on and improves word-level tracking accuracy, at the cost of more scrolling.")
                }

                Section {
                    LabeledContent("Line-jump noise (σ)") {
                        Text(model.tracker.state.calibStdPx.map { String(format: "%.0fpx", $0) } ?? "not measured")
                    }
                    LabeledContent("Measured error") {
                        Text(model.tracker.state.measuredErrPx.map { String(format: "%.0fpx", $0) } ?? "not measured")
                    }
                } header: {
                    Text("Calibration")
                } footer: {
                    Text("Measured during the accuracy-check dot at the end of calibration. Used as the noise scale for deciding whether a gaze deviation is a genuine jump.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
