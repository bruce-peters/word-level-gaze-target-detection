// Wire format for a finished reading session -- written to a local JSON
// file by SessionStorage and POSTed to Supabase by SupabaseClient, so both
// paths share one encoder (see ReadingSessionPayload.encoder) and one set of
// field names, matching supabase/migrations/0001_reading_sessions.sql.

import Foundation

/// A single dwell on one word: either one entry in the ordered fixation
/// trail (SessionRecorder.fixations), or one row of the aggregated heatmap.
struct WordVisit: Codable, Equatable {
    let wordIndex: Int
    let word: String
    let seconds: Double
}

struct ReadingSessionPayload: Codable {
    let id: UUID
    let participantName: String
    let participantAge: Int
    let readingProficiency: String
    let passageId: String
    let passageTitle: String
    let passageDifficulty: String
    let startedAt: Date
    let finishedAt: Date
    let durationSeconds: Double
    let wordCount: Int
    let heatmap: [WordVisit]
    let fixations: [WordVisit]
    let deviceModel: String
    let appVersion: String

    static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    static var decoder: JSONDecoder {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
