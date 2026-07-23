// Passage text + word/line/sentence layout.
//
// Direct port of python_app/reading/layout.py (itself a port of app.js's
// renderPassage()/buildLayout()/buildSentences()). WebGazer's world used DOM
// <span> elements measured with getBoundingClientRect(); the Tk port used a
// Canvas + font.measure(); here we measure with UIFont/NSString sizing and
// lay words out manually (no UIKit line-wrapping involved), so the resulting
// per-word frames are exactly known -- the same ground truth geometry the
// tracker snaps gaze onto.

import UIKit
import SwiftUI
import Combine
import Foundation

let PASSAGE_TEXT =
    "A Hare was making fun of the Tortoise one day for being so slow. " +
    "\"Do you ever get anywhere?\" he asked with a mocking laugh. " +
    "\"Yes,\" replied the Tortoise, \"and I get there sooner than you think. " +
    "I'll run you a race and prove it.\" " +
    "The Hare was much amused at the idea of running a race with the " +
    "Tortoise, but for the fun of the thing he agreed. So the Fox, who had " +
    "consented to act as judge, marked the distance and started the runners " +
    "off. " +
    "The Hare was soon far out of sight, and to make the Tortoise feel very " +
    "deeply how ridiculous it was for him to try a race with a Hare, he lay " +
    "down beside the course to take a nap until the Tortoise should catch " +
    "up. " +
    "The Tortoise meanwhile kept going slowly but steadily, and, after a " +
    "time, passed the place where the Hare was sleeping. But the Hare slept " +
    "on very peacefully; and when at last he did wake up, the Tortoise was " +
    "near the goal. The Hare now ran his swiftest, but he could not overtake " +
    "the Tortoise in time."

struct Word: Identifiable {
    let id: Int
    let text: String
    var lineIndex: Int = -1
    var xStart: CGFloat = 0
    var xEnd: CGFloat = 0
    var yCenter: CGFloat = 0
    var lineHeight: CGFloat = 0
    var orderIndex: Int = -1
    var sentenceIndex: Int = -1

    var xCenter: CGFloat { (xStart + xEnd) / 2 }
    var width: CGFloat { xEnd - xStart }
}

struct Line {
    let lineIndex: Int
    var yCenter: CGFloat
    var xMin: CGFloat
    var xMax: CGFloat
    var wordIDs: [Int]
    var width: CGFloat { xMax - xMin }
}

struct Sentence {
    let index: Int
    let startWordID: Int
    let wordIDs: [Int]
    let xMin: CGFloat
    let xMax: CGFloat
    let yMin: CGFloat
    let yMax: CGFloat
}

/// Two words count as "same line" when their vertical centers are within
/// this many points -- mirrors ROW_TOL in layout.py. Not actually used here
/// since we control wrapping ourselves (each wrap decision is explicit), but
/// kept for parity/documentation.
let ROW_TOL: CGFloat = 12

private let SENTENCE_END_RE = try! NSRegularExpression(pattern: "[.!?][\"'\\)\\]]*(-+)?$")

final class LayoutModel: ObservableObject {
    @Published private(set) var words: [Word] = []
    @Published private(set) var lines: [Line] = []
    @Published private(set) var sentences: [Sentence] = []
    private(set) var readOrder: [Int] = []
    private(set) var builtWidth: CGFloat = 0

    let font: UIFont
    let xPad: CGFloat
    let yPad: CGFloat

    init(font: UIFont, xPad: CGFloat = 20, yPad: CGFloat = 28) {
        self.font = font
        self.xPad = xPad
        self.yPad = yPad
    }

    /// SwiftUI-side equivalent of `font`, built from the same name/size so
    /// rendered word glyphs line up with the NSString-measured layout below.
    var swiftUIFont: Font {
        Font.custom(font.fontName, size: font.pointSize)
    }

    var contentHeight: CGFloat {
        (lines.last?.yCenter ?? 0) + font.lineHeight
    }

    /// (Re)lay out the passage against `width`. Mirrors renderPassage() +
    /// buildLayout() + buildSentences() -- one continuous word-wrapped block
    /// (the source passage has no real paragraph breaks once whitespace is
    /// collapsed, matching the web/python apps).
    func build(width: CGFloat) {
        guard width > 1 else { return }
        builtWidth = width

        let lineHeight = font.lineHeight
        let spaceWidth = widthOf(" ")
        let maxX = width - xPad

        var newWords: [Word] = []
        var rowWordIDs: [[Int]] = [[]]
        var rowYCenters: [CGFloat] = [yPad + lineHeight / 2]

        var wid = 0
        var y = rowYCenters[0]
        var x = xPad

        let tokens = PASSAGE_TEXT.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        for token in tokens {
            let text = String(token)
            let w = widthOf(text)
            if x + w > maxX && x > xPad {
                x = xPad
                y += lineHeight
                rowWordIDs.append([])
                rowYCenters.append(y)
            }
            let word = Word(id: wid, text: text, xStart: x, xEnd: x + w, yCenter: y, lineHeight: lineHeight)
            newWords.append(word)
            rowWordIDs[rowWordIDs.count - 1].append(wid)
            x = word.xEnd + spaceWidth
            wid += 1
        }

        var builtLines: [Line] = []
        var order: [Int] = []
        for (i, ids) in rowWordIDs.enumerated() where !ids.isEmpty {
            let lineIndex = builtLines.count
            var xMin = CGFloat.greatestFiniteMagnitude
            var xMax: CGFloat = 0
            for wid in ids {
                newWords[wid].lineIndex = lineIndex
                newWords[wid].orderIndex = order.count
                order.append(wid)
                xMin = min(xMin, newWords[wid].xStart)
                xMax = max(xMax, newWords[wid].xEnd)
            }
            builtLines.append(Line(lineIndex: lineIndex, yCenter: rowYCenters[i], xMin: xMin, xMax: xMax, wordIDs: ids))
        }

        self.words = newWords
        self.lines = builtLines
        self.readOrder = order
        buildSentences()
    }

    private func widthOf(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    private func buildSentences() {
        var result: [Sentence] = []
        var curIDs: [Int] = []
        var curStart: Int? = nil

        func finalize() {
            guard let start = curStart, !curIDs.isEmpty else { return }
            let xMin = curIDs.map { words[$0].xStart }.min()!
            let xMax = curIDs.map { words[$0].xEnd }.max()!
            let yMin = curIDs.map { words[$0].yCenter }.min()!
            let yMax = curIDs.map { words[$0].yCenter }.max()!
            result.append(Sentence(index: result.count, startWordID: start, wordIDs: curIDs, xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax))
            curIDs = []
            curStart = nil
        }

        for wid in readOrder {
            if curStart == nil { curStart = wid }
            curIDs.append(wid)
            words[wid].sentenceIndex = result.count
            let text = words[wid].text
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if SENTENCE_END_RE.firstMatch(in: text, range: range) != nil {
                finalize()
            }
        }
        finalize()
        self.sentences = result
    }
}
