// SessionStore.swift — Persistent session manager across app launches.

import Foundation

/// Manages recording sessions that survive app restarts.
///
/// ## Typical usage
/// ```swift
/// // App launch
/// let session = try await SessionStore.shared.startNewSession()
/// let plugin  = MoyaRecorderPlugin(session: session)
///
/// // On stop / entering background
/// try await SessionStore.shared.persist(session)
///
/// // Browse & export
/// let items = try await SessionStore.shared.listSessions()
/// let url   = try await SessionStore.shared.exportSession(id: items[0].meta.id)
/// ```
///
/// Sessions whose `lastUpdatedAt` is older than 7 days are automatically deleted
/// whenever `startNewSession()` is called.
public actor SessionStore {
    public static let shared = SessionStore()

    private let baseDirectory: URL
    private var currentSessionID: String?

    private static let fileExtension = "nrsession"
    private static let purgeCutoff: TimeInterval = 7 * 24 * 3600

    public init(directory: URL? = nil) {
        if let directory {
            baseDirectory = directory
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
            baseDirectory = appSupport
                .appendingPathComponent("ios-network-recorder", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
    }

    // MARK: - Session lifecycle

    /// Creates a new `RecordingSession`, persists its initial metadata, and returns it.
    /// Automatically purges sessions not updated in the last 7 days.
    @discardableResult
    public func startNewSession() throws -> RecordingSession {
        try FileManager.default.createDirectory(
            at: baseDirectory, withIntermediateDirectories: true, attributes: nil
        )
        purgeExpiredSessions()

        let session = RecordingSession()
        currentSessionID = session.id

        let meta = SessionMeta(
            id: session.id,
            startedAt: session.startedAt,
            lastUpdatedAt: session.startedAt,
            entryCount: 0
        )
        try write(PersistedSession(meta: meta, entries: []))
        return session
    }

    /// Serialises the session's current entries to disk and updates `lastUpdatedAt`.
    /// Call on `stopRecording()` and when the app enters the background.
    public func persist(_ session: RecordingSession) async throws {
        let entries = await session.snapshot()
        let updated = await session.lastUpdatedAt() ?? session.startedAt
        let meta = SessionMeta(
            id: session.id,
            startedAt: session.startedAt,
            lastUpdatedAt: updated,
            entryCount: entries.count
        )
        try write(PersistedSession(meta: meta, entries: entries))
    }

    // MARK: - Query

    /// All sessions sorted by `startedAt` descending (newest first).
    /// The session from the current app launch has `isCurrentSession == true`.
    public func listSessions() throws -> [SessionListItem] {
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else { return [] }

        return try sessionURLs()
            .compactMap { url -> SessionListItem? in
                let data = try Data(contentsOf: url)
                let persisted = try Self.decoder.decode(PersistedSession.self, from: data)
                return SessionListItem(
                    meta: persisted.meta,
                    isCurrentSession: persisted.meta.id == currentSessionID
                )
            }
            .sorted { $0.meta.startedAt > $1.meta.startedAt }
    }

    // MARK: - Export & delete

    /// Exports the session as a standard HAR 1.2 file in the system temp directory.
    public func exportSession(id: String) throws -> URL {
        let data = try Data(contentsOf: fileURL(id: id))
        let persisted = try Self.decoder.decode(PersistedSession.self, from: data)

        let doc = HARDocument(log: HARLog(
            creator: HARCreator(name: "ios-network-recorder", version: "0.1.0"),
            entries: persisted.entries
        ))
        let encoded = try Self.encoder.encode(doc)

        let stamp = HARDateFormatter.filenameSafe(persisted.meta.startedAt)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(stamp).har")
        try encoded.write(to: url, options: .atomic)
        return url
    }

    /// Permanently removes the session file from disk.
    public func deleteSession(id: String) throws {
        try FileManager.default.removeItem(at: fileURL(id: id))
    }

    // MARK: - Private

    private func purgeExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-Self.purgeCutoff)
        (try? sessionURLs())?.forEach { url in
            guard let data = try? Data(contentsOf: url),
                  let persisted = try? Self.decoder.decode(PersistedSession.self, from: data),
                  persisted.meta.lastUpdatedAt < cutoff
            else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ persisted: PersistedSession) throws {
        let data = try Self.encoder.encode(persisted)
        try data.write(to: fileURL(id: persisted.meta.id), options: .atomic)
    }

    private func fileURL(id: String) -> URL {
        baseDirectory.appendingPathComponent("\(id).\(Self.fileExtension)")
    }

    private func sessionURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == Self.fileExtension }
    }

    // MARK: - Coders (shared ISO 8601 date strategy)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(HARDateFormatter.iso8601.string(from: date))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = HARDateFormatter.iso8601.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "Invalid ISO 8601 date: \(s)"
                )
            }
            return date
        }
        return d
    }()
}

// MARK: - Storage model (internal)

private struct PersistedSession: Codable {
    var meta: SessionMeta
    var entries: [HAREntry]
}
