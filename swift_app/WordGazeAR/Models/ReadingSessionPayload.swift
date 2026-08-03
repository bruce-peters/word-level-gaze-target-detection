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

    // Ours-vs-Apple's-own-`lookAtPoint` accuracy-check comparison (see
    // AppModel.finishAccuracyCheck / ARKIT_GAZE_RESEARCH.md). Optional so
    // older locally-saved pending-upload JSON (from before this field
    // existed) still decodes: a run where the baseline pipeline never
    // fitted just leaves the baseline* fields nil. Recorded on every
    // session so testing accumulates an aggregate N-sessions comparison,
    // not just one anecdote.
    let oursErrorPx: Double?
    let oursStdPx: Double?
    let baselineErrorPx: Double?
    let baselineStdPx: Double?
    let avgWordWidthPx: Double?

    init(id: UUID, participantName: String, participantAge: Int, readingProficiency: String,
         passageId: String, passageTitle: String, passageDifficulty: String,
         startedAt: Date, finishedAt: Date, durationSeconds: Double, wordCount: Int,
         heatmap: [WordVisit], fixations: [WordVisit], deviceModel: String, appVersion: String,
         oursErrorPx: Double? = nil, oursStdPx: Double? = nil,
         baselineErrorPx: Double? = nil, baselineStdPx: Double? = nil,
         avgWordWidthPx: Double? = nil) {
        self.id = id
        self.participantName = participantName
        self.participantAge = participantAge
        self.readingProficiency = readingProficiency
        self.passageId = passageId
        self.passageTitle = passageTitle
        self.passageDifficulty = passageDifficulty
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.heatmap = heatmap
        self.fixations = fixations
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.oursErrorPx = oursErrorPx
        self.oursStdPx = oursStdPx
        self.baselineErrorPx = baselineErrorPx
        self.baselineStdPx = baselineStdPx
        self.avgWordWidthPx = avgWordWidthPx
    }

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
