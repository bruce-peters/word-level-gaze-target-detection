// Post-reading playback: steps through the just-finished session's fixation
// trail (ReadingSessionPayload.fixations -- the same ordered (word, seconds)
// data recorded by SessionRecorder) at 3x speed, so a tester can quickly
// sanity-check how well tracking actually followed the participant's
// reading. Reuses model.layout's word geometry, which is still the finished
// passage's layout at this point -- AppModel.returnHomeAfterSummary (called
// by SessionSummaryView's "Done") is the point where a new passage gets
// swapped in, and this view is dismissed well before that.

import SwiftUI

struct ReplayView: View {
    @ObservedObject var model: AppModel
    let payload: ReadingSessionPayload
    @Environment(\.dismiss) private var dismiss

    private let speed: Double = 3.0

    @State private var currentWordID: Int? = nil
    @State private var visited: Set<Int> = []
    @State private var finished = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        ForEach(model.layout.words) { word in
                            wordText(word)
                                .id(word.id)
                                .position(x: word.xCenter, y: word.yCenter)
                        }
                    }
                    .frame(width: max(model.layout.builtWidth, 1),
                           height: model.layout.contentHeight,
                           alignment: .topLeading)
                }
                .onChange(of: currentWordID) { wid in
                    guard let wid else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(wid, anchor: .center)
                    }
                }
            }
        }
        .background(Color(red: 0.043, green: 0.051, blue: 0.071))
        .task { await runPlayback() }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(finished ? "Replay finished" : "Replay — 3x speed")
                .font(.subheadline).bold()
                .foregroundColor(.white)
            Spacer()
            Button(finished ? "Done" : "Skip") { dismiss() }
                .buttonStyle(PillButtonStyle(color: Color(red: 0.145, green: 0.388, blue: 0.922)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.067, green: 0.078, blue: 0.094))
    }

    private func wordText(_ word: Word) -> some View {
        let isCurrent = word.id == currentWordID
        let isVisited = visited.contains(word.id)
        return Text(word.text)
            .font(model.layout.swiftUIFont)
            .foregroundColor(isCurrent ? Color(red: 0.067, green: 0.075, blue: 0.094) : Color(white: 0.9))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                isCurrent ? Color(red: 0.961, green: 0.62, blue: 0.043)
                    : isVisited ? Color(red: 0.118, green: 0.161, blue: 0.231).opacity(0.35)
                    : Color.clear
            )
            .cornerRadius(3)
    }

    /// Walks the recorded fixation trail in order, holding each word on
    /// screen for its recorded dwell time divided by `speed`. Cancelled
    /// automatically by SwiftUI's `.task` when the view is dismissed (e.g.
    /// via Skip), so there's no separate teardown to wire up.
    private func runPlayback() async {
        for fixation in payload.fixations {
            if Task.isCancelled { return }
            if let previous = currentWordID { visited.insert(previous) }
            currentWordID = fixation.wordIndex
            let delaySeconds = max(fixation.seconds / speed, 0.02)
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if Task.isCancelled { return }
        if let last = currentWordID { visited.insert(last) }
        finished = true
    }
}
