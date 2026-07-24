// Top-level coordinator: owns the ARKit gaze source, the calibrator/filter,
// the passage layout, and the tracker, and wires ARGazeEstimator's samples
// through the same pipeline app.js's onGaze() / app_window.py's
// _poll_gaze() run: predict screen point -> One-Euro filter -> Tracker.

import SwiftUI
import Combine
import Foundation

enum AppPhase {
    case welcome
    case calibrating
    case accuracyCheck
    case reading
}

final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .welcome
    @Published var calibError: String? = nil

    @Published var rawPoint: CGPoint? = nil
    @Published var filteredPoint: CGPoint? = nil
    @Published var faceVisible = false
    @Published var sourceError: String? = nil

    @Published var hudLines: [String] = []
    @Published var zcutFlash = false
    @Published var relocationFlashWordID: Int? = nil

    @Published var accuracyResultText: String? = nil
    @Published var accuracyReady = false

    let gaze = ARGazeEstimator()
    let calibrator = Calibrator()
    private let filter = GazeFilter()
    let layout: LayoutModel
    let tracker: Tracker
    let dynamicY = DynamicYCalibrator()

    /// Updated every animation frame by the pursuit-calibration dot as it
    /// moves; `pursuitActive` flips true once the view has sent its first
    /// point, so `handleSample` doesn't pair early samples with the (0,0)
    /// default before the dot has actually started moving.
    private var pursuitActive = false
    private var pursuitTargetPoint: CGPoint = .zero

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
        let layoutModel = LayoutModel(font: font)
        self.layout = layoutModel
        self.tracker = Tracker(layout: layoutModel)

        gaze.onSample = { [weak self] sample in
            self?.handleSample(sample)
        }
        gaze.$lastError
            .receive(on: DispatchQueue.main)
            .assign(to: &$sourceError)
        gaze.$faceVisible
            .receive(on: DispatchQueue.main)
            .assign(to: &$faceVisible)
    }

    // MARK: - phase transitions

    func beginCalibration() {
        calibError = nil
        pursuitActive = false
        calibrator.clear()
        dynamicY.reset()
        tracker.state.calibStdPx = nil
        tracker.state.measuredErrPx = nil
        accuracyResultText = nil
        accuracyReady = false
        gaze.start()
        phase = .calibrating
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
        accuracyResultText = nil
        accuracyReady = false
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

    private func finishAccuracyCheck() {
        accuracyActive = false
        guard accuracySamples.count >= 5 else {
            accuracyResultText = "Not enough gaze samples -- check lighting and keep your face in frame, then try again."
            accuracyReady = true
            return
        }

        let n = CGFloat(accuracySamples.count)
        let meanX = accuracySamples.reduce(CGFloat(0)) { $0 + $1.x } / n
        let meanY = accuracySamples.reduce(CGFloat(0)) { $0 + $1.y } / n
        let dx = meanX - accuracyTargetPoint.x
        let dy = meanY - accuracyTargetPoint.y
        let errPx = (dx * dx + dy * dy).squareRoot()
        let varSum = accuracySamples.reduce(CGFloat(0)) { acc, p in
            let ddx = p.x - meanX
            let ddy = p.y - meanY
            return acc + ddx * ddx + ddy * ddy
        }
        let stdPx = (varSum / n).squareRoot()

        // This is the payoff: calibStdPx feeds Tracker.jumpSigma(), which
        // sets the huge-jump threshold (JUMP_K * sigma) -- so the jump
        // detector is now scaled to this user's actually-measured noise
        // instead of a generic line-gap fallback.
        tracker.state.measuredErrPx = errPx
        tracker.state.calibStdPx = stdPx

        let gap = tracker.estimateLineGap()
        let verdict: String
        if errPx < gap {
            verdict = "good enough for line-level tracking."
        } else if errPx < gap * 2 {
            verdict = "usable, expect some drift."
        } else {
            verdict = "coarse -- consider recalibrating or improving lighting."
        }
        accuracyResultText = String(
            format: "Mean error \u{2248} %.0fpx, noise \u{03C3} \u{2248} %.0fpx (line gap \u{2248} %.0fpx). %@",
            errPx, stdPx, gap, verdict
        )
        accuracyReady = true
    }

    func finishAccuracyAndStartReading() {
        startReading()
    }

    func startReading() {
        filter.reset()
        tracker.startTracking()
        phase = .reading
    }

    func restart() {
        gaze.stop()
        calibrator.clear()
        dynamicY.reset()
        pursuitActive = false
        rawPoint = nil
        filteredPoint = nil
        accuracyResultText = nil
        accuracyReady = false
        phase = .welcome
    }

    func resetTracking() {
        filter.reset()
        tracker.startTracking()
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
        }
        contentOrigin = origin
    }

    // MARK: - forced relocation (double-tap a word)

    func forceRelocate(wordID: Int) {
        let w = tracker.forceRelocate(wordID: wordID, nowMs: ARGazeEstimator.nowMs())
        dynamicY.discardCurrentLine()
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
        }

        guard calibrator.isFitted, let raw = calibrator.predict(gx: sample.gx, gy: sample.gy) else { return }
        rawPoint = raw

        if phase == .accuracyCheck, accuracyActive {
            accuracySamples.append(raw)
        }

        guard phase == .reading else { return }
        let filtered = filter.filter(x: Double(raw.x), y: Double(raw.y), tSec: sample.timestampMs / 1000)
        filteredPoint = filtered

        let contentX = filtered.x - contentOrigin.x
        let contentY = filtered.y - contentOrigin.y

        // Feed this line's raw (pre-dynamic-calibration) Y into the rolling
        // per-line average *before* asking the tracker to assign a line, so
        // it's attributed to whichever line was active going into this
        // sample -- then hand the tracker the dynamic-Y-corrected value.
        let lineBefore = tracker.state.currentLine
        dynamicY.recordSample(rawY: contentY)
        let calibratedY = dynamicY.calibrate(contentY)

        let zcut = tracker.processGaze(gx: contentX, gy: calibratedY, nowMs: sample.timestampMs)

        if tracker.state.currentLine != lineBefore {
            if tracker.state.lineAdvancedBy == .zcut, layout.lines.indices.contains(lineBefore) {
                // The line we were just reading is confirmed finished --
                // pair its accumulated raw-Y average with its true center
                // and refit. Mirrors app.js's finishCurrentLine().
                dynamicY.finishLine(trueY: layout.lines[lineBefore].yCenter)
            } else {
                // Line changed via a huge-jump or forced relocation, not a
                // clean read of the old line -- discard rather than pair,
                // so a jump-tainted average never poisons the regression.
                dynamicY.discardCurrentLine()
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
        lines.append(String(format: "Y-calib k=%.2f b=%.0f (n=%d pairs)", dynamicY.k, dynamicY.b, dynamicY.pairs.count))
        hudLines = lines

        if zcut {
            zcutFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.zcutFlash = false }
        }
    }
}
