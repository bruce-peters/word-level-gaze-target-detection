// Renders a single passage word at its pre-computed layout position, with
// line/word/read-trail highlight state read from the shared Tracker.state.
// Mirrors updateHighlights()/paintReadTrail() in app.js and
// app_window.py's _paint_word -- the read-trail is the paper's central
// "See Where You Read" payoff: every word up to the furthest point reached
// stays tinted, so a line jump never loses your place.

import SwiftUI

struct WordView: View {
    let word: Word
    @ObservedObject var state: TrackState
    let flashWordID: Int?
    let font: Font
    let onDoubleTap: () -> Void

    private enum Level { case none, readTrail, line, word }

    private var level: Level {
        if word.id == state.currentWordID { return .word }
        if word.lineIndex == state.currentLine { return .line }
        if word.orderIndex <= state.maxOrderReached { return .readTrail }
        return .none
    }

    var body: some View {
        Text(word.text)
            .font(font)
            .foregroundColor(level == .word ? Color(red: 0.067, green: 0.075, blue: 0.094) : Color(white: 0.9))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(backgroundColor)
            .cornerRadius(3)
            .position(x: word.xCenter, y: word.yCenter)
            .onTapGesture(count: 2, perform: onDoubleTap)
    }

    private var backgroundColor: Color {
        if flashWordID == word.id { return Color(red: 0.231, green: 0.51, blue: 0.965) }
        switch level {
        case .word: return Color(red: 0.961, green: 0.62, blue: 0.043)
        case .line: return Color(red: 0.118, green: 0.161, blue: 0.231)
        case .readTrail: return Color(red: 0.118, green: 0.161, blue: 0.231).opacity(0.35)
        case .none: return .clear
        }
    }
}
