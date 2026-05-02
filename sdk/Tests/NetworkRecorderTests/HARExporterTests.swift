// HARExporterTests.swift — Unit tests for HARExporter (T4).

import XCTest
@testable import NetworkRecorder

final class HARExporterTests: XCTestCase {

    // MARK: - Test setup

    private var testDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Each test gets its own temp subdirectory to avoid name collisions.
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(at: testDirectory)
    }

    // MARK: - Helpers

    private func makePopulatedSession() async -> RecordingSession {
        let session = RecordingSession(creatorName: "TestTool", creatorVersion: "1.0.0")
        await session.startRecording()

        let timings = HARTimings(send: 0, wait: 150, receive: 0)
        let entry = HAREntry(
            startedDateTime: Date(timeIntervalSinceReferenceDate: 1000),
            time: timings.send + timings.wait + timings.receive,
            request: HARRequest(
                method: "GET",
                url: "https://api.example.com/users",
                headers: [HARNameValue(name: "Accept", value: "application/json")],
                queryString: [],
                bodySize: -1
            ),
            response: HARResponse(
                status: 200,
                statusText: "OK",
                headers: [HARNameValue(name: "Content-Type", value: "application/json")],
                content: HARContent(
                    size: 15,
                    mimeType: "application/json",
                    text: "{\"id\":1,\"ok\":true}"
                ),
                bodySize: 15
            ),
            timings: timings
        )
        await session.append(entry)
        return session
    }

    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let d = HARDateFormatter.iso8601.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    in: c,
                    debugDescription: "Cannot parse date: \(s)"
                )
            }
            return d
        }
        return dec
    }

    // MARK: - Tests

    func test_exportToFile_roundTripsThroughJSON() async throws {
        let session = await makePopulatedSession()
        let exporter = HARExporter()

        let url = try await exporter.exportToFile(session: session, directory: testDirectory)
        let data = try Data(contentsOf: url)
        let decoded = try makeDecoder().decode(HARDocument.self, from: data)

        let original = await session.makeDocument()
        XCTAssertEqual(decoded.log.version, "1.2")
        XCTAssertEqual(decoded.log.creator.name, original.log.creator.name)
        XCTAssertEqual(decoded.log.entries.count, original.log.entries.count)

        let decodedEntry = try XCTUnwrap(decoded.log.entries.first)
        let originalEntry = try XCTUnwrap(original.log.entries.first)
        XCTAssertEqual(decodedEntry.response.status, originalEntry.response.status)
        XCTAssertEqual(decodedEntry.timings.wait, originalEntry.timings.wait)
    }

    func test_exportToFile_filenameMatchesPattern() async throws {
        let session = RecordingSession()
        let exporter = HARExporter()
        let url = try await exporter.exportToFile(session: session, directory: testDirectory)
        let filename = url.lastPathComponent
        // Pattern: session-YYYY-MM-DDTHH-MM-SS.sss±HH-MM.har (colons replaced with dashes)
        let pattern = #"^session-\d{4}-\d{2}-\d{2}T.*\.har$"#
        XCTAssertNotNil(
            filename.range(of: pattern, options: .regularExpression),
            "Filename '\(filename)' does not match expected pattern '\(pattern)'"
        )
    }

    func test_exportToFile_filenameSafeForFilesystem() async throws {
        let session = RecordingSession()
        let exporter = HARExporter()
        let url = try await exporter.exportToFile(session: session, directory: testDirectory)
        let filename = url.lastPathComponent
        XCTAssertFalse(
            filename.contains(":"),
            "Filename '\(filename)' contains colon — unsafe for some filesystems"
        )
    }

    func test_exportToFile_emptySession_writesValidEmptyEntries() async throws {
        let session = RecordingSession()
        let exporter = HARExporter()
        let url = try await exporter.exportToFile(session: session, directory: testDirectory)

        let data = try Data(contentsOf: url)
        let decoded = try makeDecoder().decode(HARDocument.self, from: data)
        XCTAssertEqual(decoded.log.entries.count, 0)
        XCTAssertEqual(decoded.log.version, "1.2")
    }

    func test_exportToFile_writesFile() async throws {
        let session = await makePopulatedSession()
        let exporter = HARExporter()
        let url = try await exporter.exportToFile(session: session, directory: testDirectory)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Exported file should exist at \(url.path)"
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "Exported file should not be empty")
    }

    func test_exportToFile_defaultDirectory_usesTempDir() async throws {
        let session = RecordingSession()
        let exporter = HARExporter()
        let url = try await exporter.exportToFile(session: session)
        // Should be in the temp directory
        XCTAssertTrue(
            url.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "Default export directory should be temporaryDirectory"
        )
        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }
}
