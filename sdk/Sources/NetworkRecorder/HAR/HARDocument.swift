// HARDocument.swift — Top-level HAR 1.2 document structure.

import Foundation

/// Top-level HAR 1.2 document. Encodes as `{ "log": HARLog }`.
public struct HARDocument: Codable, Equatable {
    public var log: HARLog

    public init(log: HARLog) {
        self.log = log
    }
}

/// HAR 1.2 log object containing version, creator, and entries.
public struct HARLog: Codable, Equatable {
    /// HAR specification version. Always "1.2".
    public var version: String
    public var creator: HARCreator
    public var entries: [HAREntry]

    public init(version: String = "1.2", creator: HARCreator, entries: [HAREntry]) {
        self.version = version
        self.creator = creator
        self.entries = entries
    }
}

/// Identifies the tool that created the HAR file.
public struct HARCreator: Codable, Equatable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}
