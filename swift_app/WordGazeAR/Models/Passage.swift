// A bank of reading passages, bundled as passages.json (see that file next
// to this one) rather than hardcoded -- lets the home screen (HomeView)
// offer a real choice of passages instead of the single fixed fable
// LayoutModel used to carry as PASSAGE_TEXT.

import Foundation

enum PassageDifficulty: String, Codable, CaseIterable, Identifiable {
    case easy
    case medium
    case long

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct Passage: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let difficulty: PassageDifficulty
    let text: String
}

/// Loads and decodes `passages.json` from the app bundle once. Falls back to
/// an empty list (surfaced by HomeView as "no passages available") if the
/// resource is missing or malformed, rather than crashing the app.
final class PassageStore {
    static let shared = PassageStore()

    let passages: [Passage]

    private init() {
        guard let url = Bundle.main.url(forResource: "passages", withExtension: "json") else {
            self.passages = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            self.passages = try JSONDecoder().decode([Passage].self, from: data)
        } catch {
            self.passages = []
        }
    }
}
