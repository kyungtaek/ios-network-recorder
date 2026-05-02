// RecordingSessionTests.swift — Unit tests for RecordingSession actor (T3).

import XCTest
@testable import NetworkRecorder

final class RecordingSessionTests: XCTestCase {

    // MARK: - Helpers

    private func makeEntry(startedAt: Date = Date()) -> HAREntry {
        HAREntry(
            startedDateTime: startedAt,
            time: 10,
            request: HARRequest(
                method: "GET",
                url: "https://example.com",
                headers: [],
                queryString: [],
                bodySize: -1
            ),
            response: HARResponse(
                status: 200,
                statusText: "OK",
                headers: [],
                content: HARContent(size: 0, mimeType: "application/json"),
                bodySize: 0
            ),
            timings: HARTimings(send: 0, wait: 10, receive: 0)
        )
    }

    // MARK: - State transitions

    func test_state_transitions_idle_recording_paused_stopped_reset() async {
        let session = RecordingSession()

        var state = await session.state()
        XCTAssertEqual(state, .idle)

        await session.startRecording()
        state = await session.state()
        XCTAssertEqual(state, .recording)

        await session.pauseRecording()
        state = await session.state()
        XCTAssertEqual(state, .paused)

        await session.resumeRecording()
        state = await session.state()
        XCTAssertEqual(state, .recording)

        await session.stopRecording()
        state = await session.state()
        XCTAssertEqual(state, .stopped)

        await session.reset()
        state = await session.state()
        XCTAssertEqual(state, .idle)
    }

    func test_startRecording_fromStopped_isAllowed() async {
        let session = RecordingSession()
        await session.startRecording()
        await session.stopRecording()
        await session.startRecording()
        let state = await session.state()
        XCTAssertEqual(state, .recording)
    }

    func test_pauseRecording_whenNotRecording_isNoop() async {
        let session = RecordingSession()
        await session.pauseRecording()  // idle → should not change
        let state = await session.state()
        XCTAssertEqual(state, .idle)
    }

    func test_stopRecording_whenPaused_transitions() async {
        let session = RecordingSession()
        await session.startRecording()
        await session.pauseRecording()
        await session.stopRecording()
        let state = await session.state()
        XCTAssertEqual(state, .stopped)
    }

    // MARK: - Entry append / snapshot

    func test_append_onlyWhenRecording() async {
        let session = RecordingSession()
        let entry = makeEntry()

        // idle — should not append
        await session.append(entry)
        var snap = await session.snapshot()
        XCTAssertEqual(snap.count, 0)

        // recording — should append
        await session.startRecording()
        await session.append(entry)
        snap = await session.snapshot()
        XCTAssertEqual(snap.count, 1)

        // paused — should not append
        await session.pauseRecording()
        await session.append(entry)
        snap = await session.snapshot()
        XCTAssertEqual(snap.count, 1)  // still 1
    }

    func test_reset_clearsEntries() async {
        let session = RecordingSession()
        await session.startRecording()
        await session.append(makeEntry())
        await session.reset()
        let snap = await session.snapshot()
        XCTAssertEqual(snap.count, 0)
    }

    func test_snapshot_sortsByStartedDateTime() async {
        let session = RecordingSession()
        await session.startRecording()

        let t1 = Date(timeIntervalSinceReferenceDate: 100)
        let t2 = Date(timeIntervalSinceReferenceDate: 200)
        let t3 = Date(timeIntervalSinceReferenceDate: 50)

        await session.append(makeEntry(startedAt: t1))
        await session.append(makeEntry(startedAt: t2))
        await session.append(makeEntry(startedAt: t3))

        let snap = await session.snapshot()
        XCTAssertEqual(snap.count, 3)
        XCTAssertEqual(snap[0].startedDateTime, t3)
        XCTAssertEqual(snap[1].startedDateTime, t1)
        XCTAssertEqual(snap[2].startedDateTime, t2)
    }

    // MARK: - PendingStore thread safety

    func test_pendingStore_insertAndPop_threadSafe() {
        let store = PendingStore()
        let iterations = 200
        let expectation = self.expectation(description: "concurrent ops complete")
        expectation.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let requestID = "req-\(i)"
            let entry = PendingEntry(
                requestID: requestID,
                startTime: Date(),
                harRequest: HARRequest(
                    method: "GET",
                    url: "https://example.com/\(i)",
                    headers: [],
                    queryString: [],
                    bodySize: -1
                ),
                httpVersion: "HTTP/1.1",
                bodyByteCount: 0
            )
            store.insert(entry)
            let popped = store.pop(requestID)
            XCTAssertNotNil(popped)
            XCTAssertEqual(popped?.requestID, requestID)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertEqual(store.count, 0)
    }

    // MARK: - PendingStore FIFO ordering

    func test_pendingStore_popByURL_returnsFIFOOrder() {
        let store = PendingStore()

        let makeEntry = { (id: String, url: String) -> PendingEntry in
            PendingEntry(
                requestID: id,
                startTime: Date(),
                harRequest: HARRequest(
                    method: "GET",
                    url: url,
                    headers: [],
                    queryString: [],
                    bodySize: -1
                ),
                httpVersion: "HTTP/1.1",
                bodyByteCount: 0
            )
        }

        let entryA = makeEntry("req-A", "https://api.example.com/users?page=1")
        let entryB = makeEntry("req-B", "https://api.example.com/users?page=2")

        store.insert(entryA)
        store.insert(entryB)

        // popByURL with just the base URL (no query string) must return A first
        let first = store.popByURL("https://api.example.com/users")
        XCTAssertEqual(
            first?.requestID,
            "req-A",
            "popByURL must return the first-inserted entry (FIFO)"
        )

        // Second pop should return B
        let second = store.popByURL("https://api.example.com/users")
        XCTAssertEqual(
            second?.requestID,
            "req-B",
            "popByURL must return the second-inserted entry next"
        )

        XCTAssertEqual(store.count, 0)
    }

    // MARK: - makeDocument

    func test_makeDocument_includesCreatorInfo() async {
        let session = RecordingSession(creatorName: "TestTool", creatorVersion: "1.2.3")
        let doc = await session.makeDocument()
        XCTAssertEqual(doc.log.creator.name, "TestTool")
        XCTAssertEqual(doc.log.creator.version, "1.2.3")
        XCTAssertEqual(doc.log.version, "1.2")
    }
}
