// Post-reading playback: steps through the just-finished session's fixation
// trail (ReadingSessionPayload.fixations -- the same ordered (word, seconds)
// data recorded by SessionRecorder) at 3x speed, so a tester can quickly
// sanity-check how well tracking actually followed the participant's
// reading. Also redraws the raw gaze dot trajectory from
// SessionRecorder.gazeTrail (still on `model.sessionRecorder` -- it isn't
// reset until the next session's start(nowMs:), so it's available here).
// Reuses model.layout's word geometry, which is still the finished passage's
// layout at this point -- AppModel.returnHomeAfterSummary (called by
// SessionSummaryView's "Done") is the point where a new passage gets
// swapped in, and this view is dismissed well before that.
//
// Scrolling is done by hand (a plain vertical offset we compute ourselves
// from the current word's known yCenter) rather than ScrollViewReader.
// scrollTo -- words here are placed with .position(x:y:), and SwiftUI's
// scrollTo resolves a .position()-ed child's bounds from its pre-offset
// layout frame, not its actual on-screen location, so it kept scrolling to
// roughly the same spot regardless of target. Since LayoutModel already
// gives us every word's exact coordinates, computing the offset ourselves
// sidesteps that entirely -- and keeps the gaze dot in the same coordinate
// space as the words it's overlaid on.

import SwiftUI

struct ReplayView: View {
    @ObservedObject var model: AppModel
    let payload: ReadingSessionPayload
    @Environment(\.dismiss) private var dismiss

    private let speed: Double = 3.0

    @State private var currentWordID: Int? = nil
    @State private var visited: Set<Int> = []
    @State private var gazePoint: CGPoint? = nil
    @State private var scrollOffsetY: CGFloat = 0
    @State private var finished = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { viewport in
                ZStack(alignment: .topLeading) {
                    ForEach(model.layout.words) { word in
                        wordText(word)
                            .position(x: word.xCenter, y: word.yCenter)
                    }
                    if let gazePoint {
                        Circle()
                            .fill(Color(red: 0.937, green: 0.267, blue: 0.267).opacity(0.85))
                            .frame(width: 14, height: 14)
                            .position(gazePoint)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: max(model.layout.builtWidth, 1),
                       height: max(model.layout.contentHeight, viewport.size.height),
                       alignment: .topLeading)
                .offset(y: -scrollOffsetY)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                .clipped()
                .onChange(of: currentWordID) { wid in
                    guard let wid, model.layout.words.indices.contains(wid) else { return }
                    scrollTo(yCenter: model.layout.words[wid].yCenter, viewportHeight: viewport.size.height)
                }
            }
        }
        .background(Color(red: 0.043, green: 0.051, blue: 0.071))
        .task {
            async let wordPlayback: Void = runWordPlayback()
            async let gazePlayback: Void = runGazePlayback()
            await wordPlayback
            await gazePlayback
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(finished ? "Replay finished" : "Replay — 3x speed")
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
                Spacer()
                Button(finished ? "Done" : "Skip") { dismiss() }
                    .buttonStyle(PillButtonStyle(color: Color(red: 0.145, green: 0.388, blue: 0.922)))
            }
            Text("Orange = tracked word · red dot = raw gaze")
                .font(.caption2)
                .foregroundColor(Color(white: 0.55))
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

    private func scrollTo(yCenter: CGFloat, viewportHeight: CGFloat) {
        let maxOffset = max(0, model.layout.contentHeight - viewportHeight)
        let target = min(max(yCenter - viewportHeight / 2, 0), maxOffset)
        withAnimation(.linear(duration: 0.15)) {
            scrollOffsetY = target
        }
    }

    /// Walks the recorded fixation trail in order, holding each word on
    /// screen for its recorded dwell time divided by `speed`.
    private func runWordPlayback() async {
        for fixation in payload.fixations {
            if Task.isCancelled { return }
            await MainActor.run {
                if let previous = currentWordID { visited.insert(previous) }
                currentWordID = fixation.wordIndex
            }
            let delaySeconds = max(fixation.seconds / speed, 0.02)
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if Task.isCancelled { return }
        await MainActor.run {
            if let last = currentWordID { visited.insert(last) }
            finished = true
        }
    }

    /// Walks the much higher-resolution raw gaze trail in parallel, spacing
    /// each point by its real recorded time gap to the next one (divided by
    /// `speed`), so the dot moves at the same effective 3x rate as the word
    /// highlight above -- both are cancelled together when the view
    /// disappears, via SwiftUI's `.task`.
    private func runGazePlayback() async {
        let trail = model.sessionRecorder.gazeTrail
        guard !trail.isEmpty else { return }
        for (index, sample) in trail.enumerated() {
            if Task.isCancelled { return }
            await MainActor.run {
                gazePoint = CGPoint(x: sample.x, y: sample.y)
            }
            let nextMs = index + 1 < trail.count ? trail[index + 1].tMs : sample.tMs
            let deltaSeconds = min(max(nextMs - sample.tMs, 0) / 1000.0, 1.0)
            let sleepSeconds = deltaSeconds / speed
            if sleepSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }
        }
    }
}
