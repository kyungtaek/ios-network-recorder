// SessionMeta.swift — Lightweight metadata for a persisted recording session.

import Foundation

/// Metadata stored alongside each recording session on disk.
public struct SessionMeta: Codable, Identifiable, Sendable {
    /// UUID assigned at session creation.
    public let id: String
    /// Time the session was created (typically app launch time).
    public let startedAt: Date
    /// Time of the last captured entry, or `startedAt` if nothing was recorded yet.
    public var lastUpdatedAt: Date
    /// Total number of HAR entries captured in this session.
    public var entryCount: Int
}

/// An item returned by `SessionStore.listSessions()`.
public struct SessionListItem: Sendable {
    public let meta: SessionMeta
    /// `true` when this session was created in the current app process.
    public let isCurrentSession: Bool
}
