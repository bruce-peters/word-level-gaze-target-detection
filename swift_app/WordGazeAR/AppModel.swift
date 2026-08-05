// Top-level coordinator: owns the ARKit gaze source, the calibrator/filter,
// the passage layout, and the tracker, and wires ARGazeEstimator's samples
// through the same pipeline app.js's onGaze() / app_window.py's
// _poll_gaze() run: predict screen point -> One-Euro filter -> Tracker.

import SwiftUI
import Combine
import Foundation

enum AppPhase {
    case home
    case welcome
    case calibrating
    case accuracyCheck
    case reading
    case summary
}

enum UploadState: Equatable {
    case idle
    case uploading
    case success
    case failed(String)
}

/// Mean error (accuracy/bias) + standard deviation (precision/noise) of
/// predicted gaze around a known target, in points. Same statistics
/// `AppModel.finishAccuracyCheck` has always computed for the engineered
/// pipeline; now computed for the baseline pipeline too, for a head-to-head
/// comparison -- see ARKIT_GAZE_RESEARCH.md.
struct AccuracyStat: Equatable {
    let errorPx: CGFloat
    let stdPx: CGFloat
}

/// How long the pursuit-calibration dot takes for one lap. Shared between
/// AppModel (which schedules the actual completion timer) and
/// CalibrationView (which animates the dot over the same span), so the two
/// can't drift out of sync.
let PURSUIT_DURATION: Double = 16.0

final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .home
    @Published var calibError: String? = nil

    /// Gates the gaze dots + current line/word/read-trail highlighting.
    /// Defaults ON: for actual blind data-collection sessions (the original
    /// reason this existed -- a live indicator of the tracked word would
    /// bias how someone reads), turn it off explicitly from ReadingView's
    /// top bar before starting a real participant. Separate from
    /// `showDebugHUD` below on purpose: you often want to watch word/line
    /// tracking on-screen without the HUD panel obstructing the passage.
    @Published var showDebugOverlay: Bool = true

    /// Gates the bottom-right HUD panel (`HUDView`) specifically. Off by
    /// default -- it's diagnostic detail (Z-cut/huge-jump internals,
    /// regression fits), not needed for the everyday "does tracking look
    /// right" check `showDebugOverlay` already covers.
    @Published var showDebugHUD: Bool = false

    // MARK: - data-collection session state (home screen, recording, upload)

    let passages: [Passage] = PassageStore.shared.passages
    @Published var participant: ParticipantInfo? = nil
    @Published var selectedPassage: Passage? = nil
    @Published var uploadState: UploadState = .idle
    @Published var pendingUploadCount: Int = SessionStorage.shared.pendingCount
    @Published var lastSessionPayload: ReadingSessionPayload? = nil
    let sessionRecorder = SessionRecorder()

    @Published var rawPoint: CGPoint? = nil
    @Published var filteredPoint: CGPoint? = nil
    @Published var faceVisible = false
    @Published var isBlinking = false
    @Published var sourceError: String? = nil

    @Published var hudLines: [String] = []
    @Published var zcutFlash = false
    @Published var relocationFlashWordID: Int? = nil

    @Published var accuracyResultText: String? = nil
    @Published var accuracyReady = false

    /// Structured comparison numbers behind `accuracyResultText`, kept
    /// around for the HUD and for `ReadingSessionPayload` so every test
    /// session silently accumulates data for the poster's aggregate
    /// ours-vs-baseline comparison, not just the on-screen text of one run.
    /// See AccuracyStat + ARKIT_GAZE_RESEARCH.md.
    @Published var oursAccuracy: AccuracyStat? = nil
    @Published var baselineAccuracy: AccuracyStat? = nil
    private(set) var avgWordWidthPx: CGFloat? = nil

    let gaze = ARGazeEstimator()
    let calibrator = Calibrator()
    private let filter = GazeFilter()
    let layout: LayoutModel
    let tracker: Tracker
    let dynamicY = DynamicYCalibrator()
    let dynamicX = DynamicXCalibrator()

    /// Baseline pipeline: calibrated straight from ARKit's own
    /// `lookAtPoint` (see ARGazeEstimator's `lax`/`lay`), run in parallel
    /// with the engineered ray/plane pipeline above using the identical
    /// Calibrator class and the identical accuracy-check measurement, so
    /// the two are a fair, paired comparison -- see ARKIT_GAZE_RESEARCH.md.
    /// Never gates or blocks the real reading session: it's supplementary
    /// instrumentation, not part of the tracked-reading experience.
    ///
    /// Deliberately NOT run through GazeFilter/One-Euro: the baseline is
    /// meant to represent "Apple's own signal, nothing else," and the
    /// accuracy-check comparison (`finishAccuracyCheck`) already measures
    /// raw predictions for both pipelines -- filtering the baseline for
    /// display but not for the reported numbers would make the overlay
    /// dot and the headline stat inconsistent with each other.
    let baselineCalibrator = Calibrator()
    @Published var baselineRawPoint: CGPoint? = nil
    private var baselineAccuracySamples: [CGPoint] = []

    /// Online I-DT fixation clustering on the engineered pipeline's final
    /// (dynamic-X/Y-calibrated) point -- see FixationDetector. Word
    /// assignment reads its `currentCentroid` instead of the raw per-frame
    /// sample; Z-cut/huge-jump line tracking is untouched (still driven by
    /// the raw per-frame point, see Tracker.processGaze).
    private let fixationDetector = FixationDetector()

    /// Updated every animation frame by the pursuit-calibration dot as it
    /// moves; `pursuitActive` flips true once the view has sent its first
    /// point, so `handleSample` doesn't pair early samples with the (0,0)
    /// default before the dot has actually started moving.
    private var pursuitActive = false
    private var pursuitTargetPoint: CGPoint = .zero
    private var pursuitToken = UUID()

    private var accuracySamples: [CGPoint] = []
    private var accuracyTargetPoint: CGPoint = .zero
    private var accuracyActive = false
    private var accuracyToken = UUID()

    /// Top-left of the passage's scrollable content, in the same root/screen
    /// coordinate space `rawPoint`/`filteredPoint` and calibration targets
    /// use. Lets gaze samples (screen space) be converted to content/document
    /// space before hitting the Tracker -- the same viewport-vs-document
    /// distinction app.js/app_window.py handle via scrollY/canvasy().
    private(set) var contentOrigin: CGPoint = .zero

    init() {
        let font = UIFont(name: "Georgia", size: 30) ?? UIFont.systemFont(ofSize: 30)
        let layoutModel = LayoutModel(font: font, text: passages.first?.text ?? "")
        self.layout = layoutModel
        self.tracker = Tracker(layout: layoutModel)
        self.selectedPassage = passages.first

        gaze.onSample = { [weak self] sample in
            self?.handleSample(sample)
        }
        gaze.$lastError
            .receive(on: DispatchQueue.main)
            .assign(to: &$sourceError)
        gaze.$faceVisible
            .receive(on: DispatchQueue.main)
            .assign(to: &$faceVisible)
        gaze.$isBlinking
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBlinking)
    }

    // MARK: - phase transitions

    /// Called by HomeView's "Continue" button. Stores the participant/
    /// passage choice, swaps the passage text into the shared LayoutModel
    /// (re-laid-out the next time ReadingView appears), and moves on to the
    /// existing welcome/calibration flow.
    func beginSession(participant: ParticipantInfo, passage: Passage) {
        self.participant = participant
        self.selectedPassage = passage
        layout.setText(passage.text)
        uploadState = .idle
        lastSessionPayload = nil
        phase = .welcome
    }

    /// "Quick test" -- HomeView's fast path for on-device iteration/demoing:
    /// skips typing in participant details and always uses the Winnie-the-
    /// Pooh passage, but otherwise goes through the exact same
    /// welcome/calibration/accuracy-check flow `beginSession` does (there's
    /// no shortcut around actually calibrating a real gaze source). Falls
    /// back to the first available passage if `winnie_the_pooh` isn't found
    /// in `passages.json` for some reason, rather than doing nothing.
    func beginQuickTest() {
        guard let passage = passages.first(where: { $0.id == "winnie_the_pooh" }) ?? passages.first else { return }
        let participant = ParticipantInfo(name: "Test", age: 25, proficiency: .medium)
        beginSession(participant: participant, passage: passage)
    }

    func beginCalibration() {
        calibError = nil
        pursuitActive = false
        calibrator.clear()
        baselineCalibrator.clear()
        dynamicY.reset()
        dynamicX.reset()
        tracker.state.calibStdPx = nil
        tracker.state.measuredErrPx = nil
        accuracyResultText = nil
        accuracyReady = false
        gaze.start()
        phase = .calibrating

        // Owns the "when is the pursuit dot done" decision via a plain
        // timer rather than trying to detect completion from inside
        // CalibrationView's per-frame TimelineView closure (that relied on
        // .onChange firing exactly once at the right instant, which turned
        // out not to be reliable -- this mirrors the already-working
        // beginAccuracyCheck timer pattern below).
        let token = UUID()
        pursuitToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + PURSUIT_DURATION) { [weak self] in
            guard let self, self.pursuitToken == token, self.phase == .calibrating else { return }
            self.finishCalibration()
        }
    }

    /// Called every animation frame by the pursuit-calibration dot as it
    /// moves, so `handleSample` knows what screen point the user is
    /// (presumably) looking at right now.
    func updatePursuitTarget(_ point: CGPoint) {
        pursuitTargetPoint = point
        pursuitActive = true
    }

    /// Builds the passage layout as soon as the screen size is known, so
    /// things that need it before ReadingView ever mounts -- namely the
    /// accuracy check's line-gap estimate -- have real geometry to work
    /// with instead of a fallback default.
    func ensureLayoutBuilt(width: CGFloat) {
        if layout.builtWidth <= 1 {
            layout.build(width: width)
        }
    }

    func setFontSize(_ size: CGFloat) {
        layout.setFontSize(size)
    }

    /// Called once the pursuit dot finishes its path. Fits the calibration
    /// on whatever samples were collected along the way; on failure the
    /// caller (CalibrationView) offers a retry that restarts the same dot
    /// animation from scratch.
    func finishCalibration() {
        do {
            try calibrator.fit()
        } catch {
            calibError = "Not enough gaze samples were captured -- keep your face in frame and try to keep your eyes on the dot the whole time, then try again."
            calibrator.clear()
            return
        }
        // Supplementary instrumentation only -- a failed baseline fit never
        // blocks or degrades the real reading session, it just means the
        // comparison numbers are unavailable for this run.
        try? baselineCalibrator.fit()

        accuracyResultText = nil
        accuracyReady = false
        oursAccuracy = nil
        baselineAccuracy = nil
        filteredPoint = nil
        phase = .accuracyCheck
    }

    // MARK: - accuracy check (measures gaze noise -> huge-jump sigma)

    /// Starts the ~3s stare-at-the-dot measurement. `dotPoint` is in the
    /// same root/screen coordinate space as calibration targets and
    /// `rawPoint`.
    func beginAccuracyCheck(dotPoint: CGPoint) {
        accuracyTargetPoint = dotPoint
        accuracySamples = []
        baselineAccuracySamples = []
        accuracyActive = true
        accuracyResultText = "Measuring... keep looking at the dot"
        accuracyReady = false

        let token = UUID()
        accuracyToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.accuracyToken == token else { return }
            self.finishAccuracyCheck()
        }
    }

    /// Mean error (bias vs. `target`) + standard deviation (noise) of a
    /// sample cloud -- the same formula for both pipelines, so the
    /// ours-vs-baseline comparison is apples-to-apples.
    private static func errorStat(samples: [CGPoint], target: CGPoint) -> AccuracyStat? {
        guard samples.count >= 5 else { return nil }
        let n = CGFloat(samples.count)
        let meanX = samples.reduce(CGFloat(0)) { $0 + $1.x } / n
        let meanY = samples.reduce(CGFloat(0)) { $0 + $1.y } / n
        let dx = meanX - target.x
        let dy = meanY - target.y
        let errPx = (dx * dx + dy * dy).squareRoot()
        let varSum = samples.reduce(CGFloat(0)) { acc, p in
            let ddx = p.x - meanX
            let ddy = p.y - meanY
            return acc + ddx * ddx + ddy * ddy
        }
        let stdPx = (varSum / n).squareRoot()
        return AccuracyStat(errorPx: errPx, stdPx: stdPx)
    }

    private func finishAccuracyCheck() {
        accuracyActive = false
        guard let ours = Self.errorStat(samples: accuracySamples, target: accuracyTargetPoint) else {
            accuracyResultText = "Not enough gaze samples -- check lighting and keep your face in frame, then try again."
            accuracyReady = true
            return
        }
        oursAccuracy = ours
        baselineAccuracy = Self.errorStat(samples: baselineAccuracySamples, target: accuracyTargetPoint)

        // This is the payoff: calibStdPx feeds Tracker.jumpSigma()/
        // fixationDispersionThreshold(), which scale the huge-jump
        // threshold and fixation-clustering tolerance to this user's
        // actually-measured noise instead of a generic fallback.
        tracker.state.measuredErrPx = ours.errorPx
        tracker.state.calibStdPx = ours.stdPx

        let gap = tracker.estimateLineGap()
        let verdict: String
        if ours.errorPx < gap {
            verdict = "good enough for line-level tracking."
        } else if ours.errorPx < gap * 2 {
            verdict = "usable, expect some drift."
        } else {
            verdict = "coarse -- consider recalibrating or improving lighting."
        }

        // Average word width in points -- lets the raw px error translate
        // directly into "are words distinguishable" instead of an abstract
        // number. Computed once here (layout is already built by the time
        // the accuracy check runs -- see ensureLayoutBuilt).
        if avgWordWidthPx == nil, !layout.words.isEmpty {
            avgWordWidthPx = layout.words.reduce(CGFloat(0)) { $0 + $1.width } / CGFloat(layout.words.count)
        }

        var text = String(
            format: "Ours: mean error \u{2248} %.0fpx, noise \u{03C3} \u{2248} %.0fpx (line gap \u{2248} %.0fpx). %@",
            ours.errorPx, ours.stdPx, gap, verdict
        )
        if let baseline = baselineAccuracy {
            text += String(format: "\nApple lookAtPoint baseline: mean error \u{2248} %.0fpx, noise \u{03C3} \u{2248} %.0fpx.", baseline.errorPx, baseline.stdPx)
            if baseline.errorPx > 0 {
                let improvementPct = (1 - ours.errorPx / baseline.errorPx) * 100
                text += String(format: " Ours is %.0f%% tighter.", improvementPct)
            }
            if let w = avgWordWidthPx, w > 0 {
                text += String(format: "\nRelative to avg word width (\u{2248}%.0fpx): ours %.1f\u{00D7}, baseline %.1f\u{00D7}.", w, ours.errorPx / w, baseline.errorPx / w)
            }
        } else {
            text += " (Apple lookAtPoint baseline unavailable this run.)"
        }
        accuracyResultText = text
        accuracyReady = true
    }

    func finishAccuracyAndStartReading() {
        startReading()
    }

    func startReading() {
        filter.reset()
        fixationDetector.reset()
        tracker.startTracking()
        sessionRecorder.start(nowMs: ARGazeEstimator.nowMs())
        phase = .reading
    }

    func restart() {
        gaze.stop()
        calibrator.clear()
        baselineCalibrator.clear()
        dynamicY.reset()
        dynamicX.reset()
        fixationDetector.reset()
        pursuitActive = false
        rawPoint = nil
        filteredPoint = nil
        baselineRawPoint = nil
        accuracyResultText = nil
        accuracyReady = false
        oursAccuracy = nil
        baselineAccuracy = nil
        phase = .welcome
    }

    func resetTracking() {
        filter.reset()
        fixationDetector.reset()
        tracker.startTracking()
    }

    // MARK: - finishing & uploading a session

    /// Called by ReadingView's "Finish" button. Stops tracking, flushes the
    /// session recorder into a payload, saves it locally (always, so the
    /// data survives even if the upload below fails or there's no network),
    /// and kicks off a best-effort Supabase upload.
    func finishReading() {
        guard let participant, let passage = selectedPassage else { return }
        gaze.stop()
        let result = sessionRecorder.finish(nowMs: ARGazeEstimator.nowMs())

        let payload = ReadingSessionPayload(
            id: UUID(),
            participantName: participant.name,
            participantAge: participant.age,
            readingProficiency: participant.proficiency.rawValue,
            passageId: passage.id,
            passageTitle: passage.title,
            passageDifficulty: passage.difficulty.rawValue,
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            durationSeconds: result.finishedAt.timeIntervalSince(result.startedAt),
            wordCount: layout.words.count,
            heatmap: result.heatmap,
            fixations: result.fixations,
            deviceModel: UIDevice.current.model,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            oursErrorPx: oursAccuracy.map { Double($0.errorPx) },
            oursStdPx: oursAccuracy.map { Double($0.stdPx) },
            baselineErrorPx: baselineAccuracy.map { Double($0.errorPx) },
            baselineStdPx: baselineAccuracy.map { Double($0.stdPx) },
            avgWordWidthPx: avgWordWidthPx.map { Double($0) }
        )

        lastSessionPayload = payload
        phase = .summary

        // Local save happens unconditionally before the upload attempt --
        // an upload failure should never be the reason this session's data
        // is lost.
        try? SessionStorage.shared.save(payload)
        pendingUploadCount = SessionStorage.shared.pendingCount

        upload(payload)
    }

    private func upload(_ payload: ReadingSessionPayload) {
        uploadState = .uploading
        Task { [weak self] in
            do {
                try await SupabaseClient.shared.insertReadingSession(payload)
                await MainActor.run {
                    SessionStorage.shared.markUploaded(payload.id)
                    self?.pendingUploadCount = SessionStorage.shared.pendingCount
                    self?.uploadState = .success
                }
            } catch {
                await MainActor.run {
                    self?.uploadState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Manual retry button on SessionSummaryView after a failed upload.
    func retryLastUpload() {
        guard let payload = lastSessionPayload else { return }
        upload(payload)
    }

    /// Retries every session still on disk whose upload never succeeded --
    /// surfaced as a "N sessions pending upload" row on HomeView.
    func retryPendingUploads() {
        for payload in SessionStorage.shared.pendingPayloads() {
            Task { [weak self] in
                do {
                    try await SupabaseClient.shared.insertReadingSession(payload)
                    await MainActor.run {
                        SessionStorage.shared.markUploaded(payload.id)
                        self?.pendingUploadCount = SessionStorage.shared.pendingCount
                    }
                } catch {
                    // Stays pending on disk; the user can retry again later.
                }
            }
        }
    }

    /// Called by SessionSummaryView's "Done" button. Keeps the participant
    /// info prefilled -- the same tester often runs several passages back
    /// to back -- but clears the passage choice and this session's state.
    func returnHomeAfterSummary() {
        selectedPassage = nil
        uploadState = .idle
        lastSessionPayload = nil
        accuracyResultText = nil
        accuracyReady = false
        rawPoint = nil
        filteredPoint = nil
        phase = .home
    }

    /// Called by ReadingView whenever the passage content's on-screen origin
    /// moves (initial layout or scrolling). A moved origin means gaze
    /// samples straddling the change would otherwise look like a sudden
    /// document-space jump, so reseed the smoother/jump detector exactly
    /// like the web app's scroll listener does (IMPROVING_LINE_JUMPS.md §6c).
    func updateContentOrigin(_ origin: CGPoint) {
        if abs(origin.y - contentOrigin.y) > 2 || abs(origin.x - contentOrigin.x) > 2 {
            tracker.state.gazeEMA = nil
            tracker.state.hugeJump.overMs = 0
            tracker.state.hugeJump.cooldownUntil = ARGazeEstimator.nowMs() + HUGE_JUMP_COOLDOWN_MS
            // A scroll is the same kind of content-space discontinuity for
            // the fixation detector as it is for the huge-jump EMA above --
            // reseed it so the next sample starts a fresh cluster instead of
            // reporting a huge (scroll-sized) dispersion against pre-scroll
            // samples.
            fixationDetector.reset()
        }
        contentOrigin = origin
    }

    // MARK: - forced relocation (double-tap a word)

    func forceRelocate(wordID: Int) {
        let nowMs = ARGazeEstimator.nowMs()
        let w = tracker.forceRelocate(wordID: wordID, nowMs: nowMs)
        dynamicY.discardCurrentLine()
        dynamicX.discardCurrentLine()
        fixationDetector.reset()
        // Double-tap bypasses handleSample's per-frame processGaze call, so
        // feed the recorder here too -- otherwise the word the user just
        // jumped away from would never get its dwell time flushed.
        sessionRecorder.update(wordID: w.id, wordText: w.text, nowMs: nowMs)
        relocationFlashWordID = w.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.relocationFlashWordID == w.id { self?.relocationFlashWordID = nil }
        }
    }

    // MARK: - sample pipeline

    private func handleSample(_ sample: GazeSample) {
        if phase == .calibrating, pursuitActive {
            calibrator.addSample(gx: sample.gx, gy: sample.gy,
                                  screenX: Double(pursuitTargetPoint.x), screenY: Double(pursuitTargetPoint.y))
            // Same pursuit target, same instant -- the baseline pipeline is
            // calibrated on identical ground truth to the engineered one,
            // so the accuracy-check comparison later is a fair, paired
            // measurement (see ARKIT_GAZE_RESEARCH.md).
            baselineCalibrator.addSample(gx: sample.lax, gy: sample.lay,
                                          screenX: Double(pursuitTargetPoint.x), screenY: Double(pursuitTargetPoint.y))
        }

        guard calibrator.isFitted, let raw = calibrator.predict(gx: sample.gx, gy: sample.gy) else { return }
        rawPoint = raw

        // Baseline prediction is best-effort and never gates the main
        // pipeline below -- if it's unfitted or fails, baselineRawPoint/
        // baselineAccuracySamples just stay empty for this run. Published
        // as-is, same as `rawPoint` above -- no filtering, see the
        // baselineCalibrator property comment for why.
        let baselineRaw = baselineCalibrator.isFitted ? baselineCalibrator.predict(gx: sample.lax, gy: sample.lay) : nil
        baselineRawPoint = baselineRaw

        if phase == .accuracyCheck, accuracyActive {
            accuracySamples.append(raw)
            if let br = baselineRaw { baselineAccuracySamples.append(br) }
        }

        guard phase == .reading else { return }
        let filtered = filter.filter(x: Double(raw.x), y: Double(raw.y), tSec: sample.timestampMs / 1000)
        filteredPoint = filtered

        let contentX = filtered.x - contentOrigin.x
        let contentY = filtered.y - contentOrigin.y

        // Same content-space conversion, but on the true raw (pre-filter)
        // point -- i.e. the same "red dot" shown live when showDebugOverlay
        // is on -- recorded purely so ReplayView can redraw the actual gaze
        // trajectory after the fact.
        sessionRecorder.recordGaze(x: Double(raw.x - contentOrigin.x), y: Double(raw.y - contentOrigin.y), nowMs: sample.timestampMs)

        // Feed this line's raw (pre-dynamic-calibration) X/Y into their
        // rolling accumulators *before* asking the tracker to assign a
        // line, so they're attributed to whichever line was active going
        // into this sample -- then hand the tracker the calibrated values.
        // X's correction matters beyond just the Z-cut: it's the same `gx`
        // Tracker.processGaze uses for word-within-line assignment too.
        let lineBefore = tracker.state.currentLine
        dynamicY.recordSample(rawY: contentY)
        dynamicX.recordSample(rawX: contentX)
        let calibratedY = dynamicY.calibrate(contentY)
        let calibratedX = dynamicX.calibrate(contentX)

        // Fixation clustering on the final (dynamic-calibrated) point,
        // tolerance scaled to this user's measured noise + the current
        // position's error-model boost (edges/bottom -- see
        // Tracker.fixationDispersionThreshold). Word assignment below uses
        // the running centroid; Z-cut/huge-jump line tracking (inside
        // processGaze) still uses the raw calibratedX/Y every frame.
        let dispersion = tracker.fixationDispersionThreshold(gx: calibratedX)
        fixationDetector.push(x: calibratedX, y: calibratedY, tMs: sample.timestampMs, dispersionPx: dispersion)
        let fixationX = fixationDetector.currentCentroid?.x

        let zcut = tracker.processGaze(gx: calibratedX, gy: calibratedY, nowMs: sample.timestampMs, fixationX: fixationX)

        if let wid = tracker.state.currentWordID, layout.words.indices.contains(wid) {
            sessionRecorder.update(wordID: wid, wordText: layout.words[wid].text, nowMs: sample.timestampMs)
        } else {
            sessionRecorder.update(wordID: nil, wordText: "", nowMs: sample.timestampMs)
        }

        if tracker.state.currentLine != lineBefore {
            if tracker.state.lineAdvancedBy == .zcut, layout.lines.indices.contains(lineBefore) {
                // The line we were just reading is confirmed finished --
                // pair its accumulated raw X/Y with its true geometry and
                // refit. Mirrors app.js's finishCurrentLine() (Y) plus the
                // dynamic-X extension IMPROVING_LINE_JUMPS.md recommended
                // but never built.
                let finishedLine = layout.lines[lineBefore]
                dynamicY.finishLine(trueY: finishedLine.yCenter)
                dynamicX.finishLine(trueXMin: finishedLine.xMin, trueXMax: finishedLine.xMax)
            } else {
                // Line changed via a huge-jump or forced relocation, not a
                // clean read of the old line -- discard rather than pair,
                // so a jump-tainted average never poisons either fit.
                dynamicY.discardCurrentLine()
                dynamicX.discardCurrentLine()
            }
        }

        updateHUD(zcut: zcut)
    }

    private func updateHUD(zcut: Bool) {
        let st = tracker.state
        var lines: [String] = []
        lines.append("line \(st.currentLine) / \(max(layout.lines.count - 1, 0))")
        if let wid = st.currentWordID, layout.words.indices.contains(wid) {
            lines.append("word: \"\(layout.words[wid].text)\"")
        } else {
            lines.append("word: -")
        }
        lines.append(String(format: "reach x=%.2f max=%.2f", st.zcutDiag.normX, st.zcutDiag.reach))
        lines.append("Z-cut: \(st.zcutDiag.reason)")
        lines.append(String(format: "huge-jump %.0f / %.0fpx (k=%.0f)", st.hugeDbg.dist, st.hugeDbg.thresh, JUMP_K))
        lines.append("last advance: \(st.lineAdvancedBy.rawValue)")
        lines.append(String(format: "Y-calib k=%.2f b=%.0f (n=%d)", dynamicY.k, dynamicY.b, dynamicY.pairCount))
        lines.append(String(format: "X-calib k=%.2f b=%.0f (n=%d)", dynamicX.k, dynamicX.b, dynamicX.pairCount))
        if let c = fixationDetector.currentCentroid {
            lines.append(String(format: "fixation @ (%.0f, %.0f)", c.x, c.y))
        } else {
            lines.append("fixation: in transit (saccade)")
        }
        hudLines = lines

        if zcut {
            zcutFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.zcutFlash = false }
        }
    }
}
