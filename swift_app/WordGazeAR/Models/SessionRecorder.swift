// Turns the tracker's frame-by-frame `currentWordID` into the two data
// products the data-collection feature wants:
//   - an ordered fixation trail: every contiguous dwell on a word, in the
//     order it was visited (revisits after leaving show up again)
//   - a heatmap: the same visits aggregated by word, i.e. total seconds
//     spent looking at each word in the passage
//
// AppModel feeds this every frame during .reading (from handleSample) and
// on forced relocation (forceRelocate), the same two places Tracker's own
// currentWordID actually changes.

import Foundation

final class SessionRecorder {
    private(set) var fixations: [WordVisit] = []
    private(set) var startedAt = Date()

    private var currentWordID: Int?
    private var currentWordText = ""
    private var enteredAtMs: Double = 0

    func start(nowMs: Double) {
        fixations = []
        currentWordID = nil
        currentWordText = ""
        enteredAtMs = nowMs
        startedAt = Date()
    }

    /// Call on every frame (or forced relocation) with the tracker's current
    /// word. A no-op unless the word actually changed since the last call.
    func update(wordID: Int?, wordText: String, nowMs: Double) {
        guard wordID != currentWordID else { return }
        flushCurrent(nowMs: nowMs)
        currentWordID = wordID
        currentWordText = wordText
        enteredAtMs = nowMs
    }

    private func flushCurrent(nowMs: Double) {
        guard let wid = currentWordID else { return }
        let seconds = max(0, (nowMs - enteredAtMs) / 1000.0)
        guard seconds > 0 else { return }
        fixations.append(WordVisit(wordIndex: wid, word: currentWordText, seconds: seconds))
    }

    /// Flushes the word being read when the session ends, and returns the
    /// full fixation trail plus the per-word aggregated heatmap.
    func finish(nowMs: Double) -> (fixations: [WordVisit], heatmap: [WordVisit], startedAt: Date, finishedAt: Date) {
        flushCurrent(nowMs: nowMs)
        currentWordID = nil
        return (fixations, Self.aggregate(fixations), startedAt, Date())
    }

    private static func aggregate(_ visits: [WordVisit]) -> [WordVisit] {
        var totals: [Int: (word: String, seconds: Double)] = [:]
        for v in visits {
            let prev = totals[v.wordIndex]?.seconds ?? 0
            totals[v.wordIndex] = (v.word, prev + v.seconds)
        }
        return totals.keys.sorted().map { wid in
            let entry = totals[wid]!
            return WordVisit(wordIndex: wid, word: entry.word, seconds: entry.seconds)
        }
    }
}
