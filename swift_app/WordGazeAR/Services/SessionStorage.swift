// Local durability for finished sessions: every payload is written to disk
// before AppModel ever attempts a Supabase upload, so a failed/offline
// upload never loses research data -- it just stays "pending" until
// retried (AppModel.retryPendingUploads / HomeView's pending-uploads row).

import Foundation

final class SessionStorage {
    static let shared = SessionStorage()

    private let fileManager = FileManager.default
    private let pendingKey = "SessionStorage.pendingUploadIDs"

    private var directory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ReadingSessions", isDirectory: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    @discardableResult
    func save(_ payload: ReadingSessionPayload) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: payload.id)
        let data = try ReadingSessionPayload.encoder.encode(payload)
        try data.write(to: url, options: .atomic)
        addPending(payload.id)
        return url
    }

    func markUploaded(_ id: UUID) {
        var pending = pendingIDs()
        pending.remove(id.uuidString)
        UserDefaults.standard.set(Array(pending), forKey: pendingKey)
    }

    var pendingCount: Int { pendingIDs().count }

    /// Re-decodes every session file still marked pending, so a failed
    /// upload can be retried without re-recording the session.
    func pendingPayloads() -> [ReadingSessionPayload] {
        pendingIDs().compactMap { idString in
            guard let id = UUID(uuidString: idString) else { return nil }
            guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
            return try? ReadingSessionPayload.decoder.decode(ReadingSessionPayload.self, from: data)
        }
    }

    private func addPending(_ id: UUID) {
        var pending = pendingIDs()
        pending.insert(id.uuidString)
        UserDefaults.standard.set(Array(pending), forKey: pendingKey)
    }

    private func pendingIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
    }
}
