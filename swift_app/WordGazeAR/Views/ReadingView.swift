// The passage itself: word-wrapped text laid out by LayoutModel, scrollable,
// with a top bar and debug HUD. Reports the scroll content's on-screen
// origin back to AppModel (see ContentOriginKey) so gaze samples -- which
// arrive in screen space -- can be converted to the passage's document space
// before being handed to the Tracker, exactly like app.js's
// `calX = vx + window.scrollX` / app_window.py's `canvas.canvasx()`.

import SwiftUI

private struct ContentOriginKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

struct ReadingView: View {
    @ObservedObject var model: AppModel
    // Observed directly (not just reached via `model.layout`) so that a
    // layout-only change -- e.g. a font-size edit from Settings, which
    // doesn't touch any of AppModel's own @Published properties -- still
    // triggers a re-render. `model.objectWillChange` alone wouldn't catch it.
    @ObservedObject private var layout: LayoutModel
    @State private var showHUD = true
    @State private var showSettings = false

    init(model: AppModel) {
        self.model = model
        self.layout = model.layout
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geo in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        GeometryReader { probe in
                            Color.clear.preference(key: ContentOriginKey.self,
                                                    value: probe.frame(in: .named("root")).origin)
                        }
                        .frame(width: 1, height: 1)

                        ForEach(layout.words) { word in
                            WordView(word: word,
                                      state: model.tracker.state,
                                      flashWordID: model.relocationFlashWordID,
                                      font: layout.swiftUIFont) {
                                model.forceRelocate(wordID: word.id)
                            }
                        }
                    }
                    .frame(width: geo.size.width,
                           height: max(layout.contentHeight, geo.size.height),
                           alignment: .topLeading)
                }
                .onAppear { layout.build(width: geo.size.width) }
                .onChange(of: geo.size.width) { newWidth in
                    layout.build(width: newWidth)
                }
                .onPreferenceChange(ContentOriginKey.self) { origin in
                    model.updateContentOrigin(origin)
                }
            }
        }
        .background(Color(red: 0.043, green: 0.051, blue: 0.071))
        .overlay(alignment: .bottomTrailing) {
            if showHUD {
                HUDView(model: model).padding(10)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Word Gaze AR").font(.subheadline).bold().foregroundColor(.white)
            Spacer()
            Button(showHUD ? "Hide HUD" : "Show HUD") { showHUD.toggle() }
                .buttonStyle(PillButtonStyle(color: Color.gray.opacity(0.4)))
            Button("Settings") { showSettings = true }
                .buttonStyle(PillButtonStyle(color: Color.gray.opacity(0.4)))
            Button("Reset") { model.resetTracking() }
                .buttonStyle(PillButtonStyle(color: Color(red: 0.145, green: 0.388, blue: 0.922)))
            Button("Recalibrate") { model.beginCalibration() }
                .buttonStyle(PillButtonStyle(color: Color.gray.opacity(0.4)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.067, green: 0.078, blue: 0.094))
    }
}
