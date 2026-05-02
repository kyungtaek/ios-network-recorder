// HARExporter.swift — Exports a RecordingSession snapshot to a HAR 1.2 file.

import Foundation

/// Exports a `RecordingSession` snapshot to a HAR 1.2 JSON file.
///
/// Usage:
/// ```swift
/// let exporter = HARExporter()
/// let url = try await exporter.exportToFile(session: mySession)
/// ```
public struct HARExporter {
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(
        fileManager: FileManager = .default,
        encoder: JSONEncoder = HARExporter.defaultEncoder()
    ) {
        self.fileManager = fileManager
        self.encoder = encoder
    }

    /// Returns a `JSONEncoder` configured for HAR 1.2 output:
    /// pretty-printed, sorted keys, and ISO 8601 dates with fractional seconds.
    public static func defaultEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(HARDateFormatter.iso8601.string(from: date))
        }
        return e
    }

    /// Exports the session snapshot to a `.har` file and returns its URL.
    ///
    /// - Parameters:
    ///   - session: The recording session to export.
    ///   - directory: Destination directory. Defaults to `FileManager.temporaryDirectory`.
    /// - Returns: URL of the written file.
    /// - Throws: `EncodingError` if JSON encoding fails, or `CocoaError` if writing fails.
    public func exportToFile(
        session: RecordingSession,
        directory: URL? = nil
    ) async throws -> URL {
        let doc = await session.makeDocument()
        let data = try encoder.encode(doc)

        let dir = directory ?? fileManager.temporaryDirectory
        let stamp = HARDateFormatter.iso8601.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")  // safe for POSIX filenames
        let url = dir.appendingPathComponent("session-\(stamp).har")
        try data.write(to: url, options: .atomic)
        return url
    }
}
