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
    case reading
}

/// The 9 calibration targets, as fractions of screen size -- identical
/// layout to ui/overlays.py's TARGET_XF / TARGET_YF.
let CALIB_TARGET_XF: [CGFloat] = [0.1, 0.5, 0.9]
let CALIB_TARGET_YF: [CGFloat] = [0.12, 0.5, 0.88]

final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .welcome
    @Published var calibDoneIndices: Set<Int> = []
    @Published var calibActiveIndex: Int? = nil
    @Published var calibError: String? = nil

    @Published var rawPoint: CGPoint? = nil
    @Published var filteredPoint: CGPoint? = nil
    @Published var faceVisible = false
    @Published var sourceError: String? = nil

    @Published var hudLines: [String] = []
    @Published var zcutFlash = false
    @Published var relocationFlashWordID: Int? = nil

    let gaze = ARGazeEstimator()
    let calibrator = Calibrator()
    private let filter = GazeFilter()
    let layout: LayoutModel
    let tracker: Tracker

    private var capturing = false
    private var activeScreenPoint: CGPoint? = nil

    /// Top-left of the passage's scrollable content, in the same root/screen
    /// coordinate space `rawPoint`/`filteredPoint` and calibration targets
    /// use. Lets gaze samples (screen space) be converted to content/document
    /// space before hitting the Tracker -- the same viewport-vs-document
    /// distinction app.js/app_window.py handle via scrollY/canvasy().
    private(set) var contentOrigin: CGPoint = .zero

    var calibrationComplete: Bool { calibDoneIndices.count >= CALIB_TARGET_XF.count * CALIB_TARGET_YF.count }

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
        calibDoneIndices = []
        calibrator.clear()
        gaze.start()
        phase = .calibrating
    }

    func beginCapture(pointIndex: Int, at screenPoint: CGPoint) {
        calibActiveIndex = pointIndex
        activeScreenPoint = screenPoint
        capturing = true
    }

    func endCapture() {
        capturing = false
        activeScreenPoint = nil
        calibActiveIndex = nil
    }

    func markPointDone(_ idx: Int) {
        calibDoneIndices.insert(idx)
    }

    func finishCalibration() {
        do {
            try calibrator.fit()
        } catch {
            calibError = "Not enough gaze samples were captured. Hold each dot a little longer, keep your face in frame, then try again."
            calibDoneIndices = []
            calibrator.clear()
            return
        }
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
        calibDoneIndices = []
        rawPoint = nil
        filteredPoint = nil
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
        relocationFlashWordID = w.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.relocationFlashWordID == w.id { self?.relocationFlashWordID = nil }
        }
    }

    // MARK: - sample pipeline

    private func handleSample(_ sample: GazeSample) {
        if capturing, let pt = activeScreenPoint {
            calibrator.addSample(pitch: sample.pitch, yaw: sample.yaw, screenX: Double(pt.x), screenY: Double(pt.y))
        }

        guard calibrator.isFitted, let raw = calibrator.predict(pitch: sample.pitch, yaw: sample.yaw) else { return }
        rawPoint = raw

        guard phase == .reading else { return }
        let filtered = filter.filter(x: Double(raw.x), y: Double(raw.y), tSec: sample.timestampMs / 1000)
        filteredPoint = filtered

        let contentX = filtered.x - contentOrigin.x
        let contentY = filtered.y - contentOrigin.y
        let zcut = tracker.processGaze(gx: contentX, gy: contentY, nowMs: sample.timestampMs)
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
        hudLines = lines

        if zcut {
            zcutFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.zcutFlash = false }
        }
    }
}
