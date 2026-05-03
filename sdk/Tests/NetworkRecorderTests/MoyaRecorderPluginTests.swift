// MoyaRecorderPluginTests.swift — Unit tests for MoyaRecorderPlugin (T3).
// Tests drive the plugin directly without spinning a real MoyaProvider.

import XCTest
@preconcurrency import Moya
@testable import NetworkRecorder

// MARK: - Test doubles

/// Minimal TargetType conformance for testing.
struct MockTarget: TargetType {
    var baseURL: URL = URL(string: "https://api.example.com")!
    var path: String = "/users"
    var method: Moya.Method = .get
    var task: Moya.Task = .requestPlain
    var headers: [String: String]? = nil
}

/// Wraps a URLRequest to conform to Moya's RequestType.
struct MockRequest: RequestType {
    let urlRequest: URLRequest

    var request: URLRequest? { urlRequest }
    var sessionHeaders: [String: String] { [:] }

    func authenticate(username: String, password: String, persistence: URLCredential.Persistence) -> MockRequest { self }
    func authenticate(with credential: URLCredential) -> MockRequest { self }
    func cURLDescription(calling handler: @escaping (String) -> Void) -> MockRequest { self }
}

// MARK: - Tests

final class MoyaRecorderPluginTests: XCTestCase {

    // MARK: - Helpers

    private func makePlugin(
        session: RecordingSession,
        clock: MockClock = MockClock()
    ) -> MoyaRecorderPlugin {
        MoyaRecorderPlugin(session: session, clock: clock)
    }

    /// Run prepare + willSend on a URLRequest and return the modified request.
    private func runPrepareAndWillSend(
        plugin: MoyaRecorderPlugin,
        request: URLRequest,
        target: TargetType = MockTarget()
    ) -> URLRequest {
        let prepared = plugin.prepare(request, target: target)
        let mockReq = MockRequest(urlRequest: prepared)
        plugin.willSend(mockReq, target: target)
        return prepared
    }

    /// Create a Moya Response with the given status code. The `request` field carries
    /// the X-NR-Request-ID header used for correlation in `didReceive`.
    private func makeResponse(
        statusCode: Int,
        data: Data = Data(),
        urlRequest: URLRequest
    ) -> Response {
        let httpResponse = HTTPURLResponse(
            url: urlRequest.url ?? URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        return Response(
            statusCode: statusCode,
            data: data,
            request: urlRequest,
            response: httpResponse
        )
    }

    /// Creates a URLError with a `failingURL` matching the given URL string.
    /// Used to trigger the URL-based fallback correlation path.
    private func makeURLError(code: URLError.Code, url: URL) -> URLError {
        URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url])
    }

    // MARK: - prepare

    func test_prepare_injectsCorrelationHeader() {
        let session = RecordingSession()
        let plugin = makePlugin(session: session)
        let request = URLRequest(url: URL(string: "https://example.com/api")!)
        let prepared = plugin.prepare(request, target: MockTarget())
        XCTAssertNotNil(
            prepared.value(forHTTPHeaderField: MoyaRecorderPlugin.correlationHeader)
        )
    }

    func test_prepare_idempotent_doesNotOverwrite() {
        let session = RecordingSession()
        let plugin = makePlugin(session: session)
        var request = URLRequest(url: URL(string: "https://example.com/api")!)
        request.setValue("existing-id", forHTTPHeaderField: MoyaRecorderPlugin.correlationHeader)
        let prepared = plugin.prepare(request, target: MockTarget())
        XCTAssertEqual(
            prepared.value(forHTTPHeaderField: MoyaRecorderPlugin.correlationHeader),
            "existing-id"
        )
    }

    // MARK: - willSend / header redaction

    func test_willSend_redactsAuthorizationHeader() async {
        let session = RecordingSession()
        let clock = MockClock(date: Date(timeIntervalSinceReferenceDate: 0))
        let plugin = makePlugin(session: session, clock: clock)

        await session.startRecording()

        var request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let prepared = runPrepareAndWillSend(plugin: plugin, request: request)
        let reqID = prepared.value(forHTTPHeaderField: MoyaRecorderPlugin.correlationHeader)!

        let pending = session.pending.pop(reqID)
        XCTAssertNotNil(pending)
        let authHeader = pending?.harRequest.headers.first { $0.name.lowercased() == "authorization" }
        XCTAssertEqual(authHeader?.value, "[REDACTED]")
    }

    func test_willSend_stripsCorrelationHeaderFromHAR() async {
        let session = RecordingSession()
        let plugin = makePlugin(session: session)

        await session.startRecording()

        let request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        let prepared = runPrepareAndWillSend(plugin: plugin, request: request)
        let reqID = prepared.value(forHTTPHeaderField: MoyaRecorderPlugin.correlationHeader)!

        let pending = session.pending.pop(reqID)
        XCTAssertNotNil(pending)
        let hasCorrelationHeader = pending?.harRequest.headers.contains {
            $0.name.lowercased() == MoyaRecorderPlugin.correlationHeader.lowercased()
        } ?? false
        XCTAssertFalse(hasCorrelationHeader, "X-NR-Request-ID should be stripped from HAR")
    }

    func test_willSend_streamingBody_writesSentinel() async {
        let session = RecordingSession()
        let plugin = makePlugin(session: session)

        await session.startRecording()

        var request = URLRequest(url: URL(string: "https://api.example.com/upload")!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // Attach a body stream (simulate streaming upload).
        let stream = InputStream(data: Data("test".utf8))
        request.httpBodyStream = stream

        let prepared = runPrepareAndWillSend(plugin: plugin, request: request)
        let reqID = prepared.value(forHTTPHeaderField: MoyaRecorderPlugin.correlationHeader)!

        let pending = session.pending.pop(reqID)
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.harRequest.postData?.text, "[streaming-body]")
        XCTAssertEqual(pending?.harRequest.bodySize, -1)
    }

    func test_willSend_capturesQueryString() async {
        let session = RecordingSession()
        let plugin = makePlugin(session: session)

        await session.startRecording()

        var components = URLComponents(string: "https://api.example.com/items")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "foo"),
            URLQueryItem(name: "limit", value: "10")
        ]
        let request = URLRequest(url: components.url!)
        let prepared = runPrepareAndWillSend(plugin: plugin, request: request)
        let reqID = prepared.value(forHTTPHeaderField: MoyaRecorderPlugin.correlationHeader)!

        let pending = session.pending.pop(reqID)
        XCTAssertNotNil(pending)
        let qs = pending?.harRequest.queryString ?? []
        let q = qs.first { $0.name == "q" }
        let limit = qs.first { $0.name == "limit" }
        XCTAssertEqual(q?.value, "foo")
        XCTAssertEqual(limit?.value, "10")
    }

    func test_willSend_capturesJSONPostBody() async {
        let session = RecordingSession()
        let plugin = makePlugin(session: session)

        await session.startRecording()

        var request = URLRequest(url: URL(string: "https://api.example.com/items")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = """
        {"name":"widget","price":9.99}
        """
        request.httpBody = Data(body.utf8)

        let prepared = runPrepareAndWillSend(plugin: plugin, request: request)
        let reqID = prepared.value(forHTTPHeaderField: MoyaRecorderPlugin.correlationHeader)!

        let pending = session.pending.pop(reqID)
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.harRequest.postData?.text, body)
        XCTAssertEqual(pending?.harRequest.postData?.mimeType, "application/json")
    }

    // MARK: - didReceive

    func test_didReceive_success_writesEntry() async throws {
        let session = RecordingSession()
        let clock = MockClock(date: Date(timeIntervalSinceReferenceDate: 0))
        let plugin = makePlugin(session: session, clock: clock)

        await session.startRecording()

        let request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        let prepared = plugin.prepare(request, target: MockTarget())
        plugin.willSend(MockRequest(urlRequest: prepared), target: MockTarget())

        // Advance clock to simulate 100ms elapsed
        clock.nowDate = Date(timeIntervalSinceReferenceDate: 0.1)

        let bodyData = Data("{\"id\":1}".utf8)
        let moyaResponse = makeResponse(statusCode: 200, data: bodyData, urlRequest: prepared)
        plugin.didReceive(.success(moyaResponse), target: MockTarget())

        // Wait for async Task { await session.append } to complete
        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)

        let entries = await session.snapshot()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.response.status, 200)
        XCTAssertEqual(entry.time, 100, accuracy: 1.0)
    }

    func test_didReceive_underlyingNoResponse_writesStubEntry() async throws {
        let session = RecordingSession()
        let clock = MockClock(date: Date(timeIntervalSinceReferenceDate: 0))
        let plugin = makePlugin(session: session, clock: clock)

        await session.startRecording()

        let targetURL = URL(string: "https://api.example.com/users")!
        let request = URLRequest(url: targetURL)
        let prepared = plugin.prepare(request, target: MockTarget())
        plugin.willSend(MockRequest(urlRequest: prepared), target: MockTarget())

        clock.nowDate = Date(timeIntervalSinceReferenceDate: 0.05)

        // URLError with failingURL so the plugin can correlate via URL-based fallback.
        let urlError = makeURLError(code: .notConnectedToInternet, url: targetURL)
        let error = MoyaError.underlying(urlError, nil)
        plugin.didReceive(.failure(error), target: MockTarget())

        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)

        let entries = await session.snapshot()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.response.status, 0)
        XCTAssertNotNil(entry.comment)
        XCTAssertTrue(entry.comment?.contains("moya-error") ?? false)
    }

    func test_didReceive_statusCode500_writesRealEntry() async throws {
        let session = RecordingSession()
        let clock = MockClock(date: Date(timeIntervalSinceReferenceDate: 0))
        let plugin = makePlugin(session: session, clock: clock)

        await session.startRecording()

        let request = URLRequest(url: URL(string: "https://api.example.com/orders")!)
        let prepared = plugin.prepare(request, target: MockTarget())
        plugin.willSend(MockRequest(urlRequest: prepared), target: MockTarget())

        clock.nowDate = Date(timeIntervalSinceReferenceDate: 0.2)

        let bodyData = Data("{\"error\":\"internal\"}".utf8)
        let moyaResponse = makeResponse(statusCode: 500, data: bodyData, urlRequest: prepared)
        let error = MoyaError.statusCode(moyaResponse)
        plugin.didReceive(.failure(error), target: MockTarget())

        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)

        let entries = await session.snapshot()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.response.status, 500)
        XCTAssertNotNil(entry.comment)
    }


    func test_didReceive_statusCode401_writesEntry() async throws {
        let session = RecordingSession()
        let clock = MockClock(date: Date(timeIntervalSinceReferenceDate: 0))
        let plugin = makePlugin(session: session, clock: clock)

        await session.startRecording()

        let request = URLRequest(url: URL(string: "https://api.example.com/secure")!)
        let prepared = plugin.prepare(request, target: MockTarget())
        plugin.willSend(MockRequest(urlRequest: prepared), target: MockTarget())

        clock.nowDate = Date(timeIntervalSinceReferenceDate: 0.15)

        let bodyData = Data("{\"error\":\"unauthorized\"}".utf8)
        let moyaResponse = makeResponse(statusCode: 401, data: bodyData, urlRequest: prepared)
        let error = MoyaError.statusCode(moyaResponse)
        plugin.didReceive(.failure(error), target: MockTarget())

        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)

        let entries = await session.snapshot()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.response.status, 401)
        XCTAssertNotNil(entry.comment)
    }

    // MARK: - Timing rules

    func test_didReceive_timingsObeyHARRules() async throws {
        let session = RecordingSession()
        let startDate = Date(timeIntervalSinceReferenceDate: 0)
        let endDate = Date(timeIntervalSinceReferenceDate: 0.3)  // 300ms
        let clock = MockClock(date: startDate)
        let plugin = makePlugin(session: session, clock: clock)

        await session.startRecording()

        let request = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let prepared = plugin.prepare(request, target: MockTarget())
        plugin.willSend(MockRequest(urlRequest: prepared), target: MockTarget())

        clock.nowDate = endDate
        let moyaResponse = makeResponse(statusCode: 200, urlRequest: prepared)
        plugin.didReceive(.success(moyaResponse), target: MockTarget())

        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)

        let entries = await session.snapshot()
        XCTAssertEqual(entries.count, 1)
        let timings = entries[0].timings

        XCTAssertEqual(timings.blocked, -1)
        XCTAssertEqual(timings.dns, -1)
        XCTAssertEqual(timings.connect, -1)
        XCTAssertEqual(timings.ssl, -1)
        XCTAssertEqual(timings.send, 0)
        XCTAssertGreaterThan(timings.wait, 0)
        XCTAssertEqual(timings.receive, 0)

        // time == send + wait + receive
        XCTAssertEqual(entries[0].time, timings.send + timings.wait + timings.receive)
    }

    // MARK: - noMasking option

    func test_noMasking_exposesAuthorizationHeader() async throws {
        let session = RecordingSession()
        let clock = MockClock()
        let plugin = MoyaRecorderPlugin(
            session: session,
            sensitiveHeaders: MoyaRecorderPlugin.noMasking,
            clock: clock
        )

        await session.startRecording()
        var req = URLRequest(url: URL(string: "https://api.example.com/users")!)
        req.setValue("Bearer secret-token-123", forHTTPHeaderField: "Authorization")

        let prepared = runPrepareAndWillSend(plugin: plugin, request: req)
        let response = makeResponse(statusCode: 200, urlRequest: prepared)
        clock.nowDate = clock.nowDate.addingTimeInterval(0.1)
        plugin.didReceive(.success(response), target: MockTarget())

        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        let entries = await session.snapshot()
        let authHeader = entries[0].request.headers.first { $0.name.lowercased() == "authorization" }
        XCTAssertEqual(authHeader?.value, "Bearer secret-token-123")
    }

    // MARK: - allowedDomains filter

    func test_allowedDomains_recordsMatchingHost() async throws {
        let session = RecordingSession()
        let clock = MockClock()
        let plugin = MoyaRecorderPlugin(
            session: session,
            allowedDomains: ["api.example.com"],
            clock: clock
        )

        await session.startRecording()
        var req = URLRequest(url: URL(string: "https://api.example.com/users")!)
        let prepared = runPrepareAndWillSend(plugin: plugin, request: req)
        let response = makeResponse(statusCode: 200, urlRequest: prepared)
        clock.nowDate = clock.nowDate.addingTimeInterval(0.1)
        plugin.didReceive(.success(response), target: MockTarget())

        // Request to a different domain — should be silently skipped.
        req = URLRequest(url: URL(string: "https://analytics.other.com/event")!)
        let prepared2 = plugin.prepare(req, target: MockTarget())
        plugin.willSend(MockRequest(urlRequest: prepared2), target: MockTarget())

        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        let entries = await session.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].request.url.contains("api.example.com"))
    }

    func test_allowedDomains_subdomainMatch() async throws {
        let session = RecordingSession()
        let clock = MockClock()
        // Specifying "example.com" should also match "api.example.com".
        let plugin = MoyaRecorderPlugin(
            session: session,
            allowedDomains: ["example.com"],
            clock: clock
        )

        await session.startRecording()
        let req = URLRequest(url: URL(string: "https://api.example.com/users")!)
        let prepared = runPrepareAndWillSend(plugin: plugin, request: req)
        let response = makeResponse(statusCode: 200, urlRequest: prepared)
        clock.nowDate = clock.nowDate.addingTimeInterval(0.1)
        plugin.didReceive(.success(response), target: MockTarget())

        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        let entries = await session.snapshot()
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - excludedQueryParams

    func test_excludedQueryParams_stripsFromQueryStringAndURL() async throws {
        let session = RecordingSession()
        let clock = MockClock()
        let plugin = MoyaRecorderPlugin(
            session: session,
            excludedQueryParams: ["md", "sig"],
            clock: clock
        )

        await session.startRecording()
        let req = URLRequest(url: URL(string: "https://api.example.com/items?q=test&limit=10&md=abc123&sig=xyz")!)
        let prepared = runPrepareAndWillSend(plugin: plugin, request: req)
        let response = makeResponse(statusCode: 200, urlRequest: prepared)
        clock.nowDate = clock.nowDate.addingTimeInterval(0.1)
        plugin.didReceive(.success(response), target: MockTarget())

        try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        let entries = await session.snapshot()
        XCTAssertEqual(entries.count, 1)

        let entry = entries[0]
        let paramNames = entry.request.queryString.map(\.name)
        XCTAssertTrue(paramNames.contains("q"))
        XCTAssertTrue(paramNames.contains("limit"))
        XCTAssertFalse(paramNames.contains("md"), "md should be excluded")
        XCTAssertFalse(paramNames.contains("sig"), "sig should be excluded")
        XCTAssertFalse(entry.request.url.contains("md="), "md should be stripped from URL")
        XCTAssertFalse(entry.request.url.contains("sig="), "sig should be stripped from URL")
    }
}
