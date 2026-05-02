// E2ERecordingTest.swift — End-to-end UI test that drives the recording session.
//
// Fires 6 APITarget cases against a running Prism mock server (http://127.0.0.1:4010),
// records the exchange via MoyaRecorderPlugin, exports a HAR file, and asserts it exists.
//
// Note: RecordingHost and APIProvider live in SampleApp/Networking/ and are shared
// into this target via XcodeGen's sources list. This avoids @testable import of the
// host app binary (which is a separate process in UI tests).
// Two separate process instances of RecordingHost.shared/APIProvider.shared exist at
// runtime — the host app's instance captures traffic, and the test process's instance
// is used here for orchestration.

import XCTest
import NetworkRecorder

class E2ERecordingTest: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Bridge a Moya completion callback to an async/await call-site.
    /// The result is intentionally ignored — we only care that the plugin captured
    /// the exchange, not whether Prism returned a success or error status.
    private func request(_ target: APITarget) async {
        await withCheckedContinuation { continuation in
            APIProvider.shared.provider.request(target) { _ in
                continuation.resume()
            }
        }
    }

    func testFullRecordingSession() async throws {
        // 1. Start recording
        await RecordingHost.shared.startRecording()

        // 2. Fire all 6 API cases sequentially, waiting for each to complete.
        await request(.usersMe)
        await request(.usersMeUnauthorized)
        await request(.items(q: "widget", limit: 10))
        await request(.createItem(name: "TestWidget", price: 9.99))
        await request(.orders)
        await request(.ordersError)

        // Allow in-flight MoyaRecorderPlugin entry-append Tasks to complete
        // before stopping (guards against actor state race on last request).
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        // 3. Stop recording
        await RecordingHost.shared.stopRecording()

        // Allow any Tasks that were already queued but blocked on the actor to drain
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // 4. Export HAR and assert the file exists on disk.
        // Print the simulator-side path so the QA harness can retrieve it via:
        //   xcrun simctl get_app_container booted <bundle-id> data
        let url = try await RecordingHost.shared.exportHAR()
        print("HAR_PATH=\(url.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
