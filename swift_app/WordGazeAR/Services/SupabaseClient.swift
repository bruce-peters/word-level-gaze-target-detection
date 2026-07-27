// Minimal REST client for writing finished sessions to Supabase's
// PostgREST endpoint -- no SDK dependency, since this source tree doesn't
// have an .xcodeproj (and therefore no Swift Package Manager graph) yet;
// see swift_app/README.md. Just a single POST per session, matching the
// reading_sessions table in supabase/migrations/0001_reading_sessions.sql.

import Foundation

enum SupabaseError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case requestFailed(status: Int, body: String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase isn't configured yet (SupabaseConfig.anonKey is blank)."
        case .invalidURL:
            return "Invalid Supabase project URL."
        case .requestFailed(let status, let body):
            return "Supabase rejected the upload (HTTP \(status)): \(body)"
        case .transport(let error):
            return error.localizedDescription
        }
    }
}

final class SupabaseClient {
    static let shared = SupabaseClient()
    private let session = URLSession.shared

    func insertReadingSession(_ payload: ReadingSessionPayload) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseError.notConfigured }
        guard let url = URL(string: "\(SupabaseConfig.projectURL)/rest/v1/reading_sessions") else {
            throw SupabaseError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try ReadingSessionPayload.encoder.encode(payload)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SupabaseError.requestFailed(status: -1, body: "no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw SupabaseError.requestFailed(status: http.statusCode, body: body)
            }
        } catch let error as SupabaseError {
            throw error
        } catch {
            throw SupabaseError.transport(error)
        }
    }
}
