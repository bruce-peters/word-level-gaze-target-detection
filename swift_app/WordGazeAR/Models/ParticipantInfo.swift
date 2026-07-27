// Participant metadata collected on the home screen (HomeView) before a
// session starts.

import Foundation

enum ReadingProficiency: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ParticipantInfo: Codable, Equatable {
    var name: String
    var age: Int
    var proficiency: ReadingProficiency
}
