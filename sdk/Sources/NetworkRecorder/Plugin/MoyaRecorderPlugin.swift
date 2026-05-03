// MoyaRecorderPlugin.swift — Moya plugin that captures requests/responses as HAR entries.

import Foundation
import Moya

/// A Moya plugin that records all network traffic into a `RecordingSession` in HAR 1.2 format.
///
/// Install by adding to `MoyaProvider(plugins: [recorderPlugin])`.
///
/// The plugin injects a correlation header (`X-NR-Request-ID`) at `prepare` time and removes
/// it from the captured HAR so it does not leak into recordings.
///
/// Sensitive headers (Authorization, Cookie, etc.) are masked with `[REDACTED]` by default.
/// Pass `sensitiveHeaders: MoyaRecorderPlugin.noMasking` to record auth tokens in plaintext
/// (e.g., when the HAR will be used to replay authenticated requests).
///
/// Use `allowedDomains` to record only traffic to specific hosts.
/// Use `excludedQueryParams` to strip dynamic params (e.g. HMAC signatures) from HAR entries.
public final class MoyaRecorderPlugin: PluginType {
    /// Name of the internal correlation header injected into every request.
    public static let correlationHeader = "X-NR-Request-ID"

    /// Default set of header names whose values are replaced with `[REDACTED]` in HAR output.
    public static let defaultSensitiveHeaders: Set<String> = [
        "Authorization",
        "Cookie",
        "Set-Cookie",
        "Proxy-Authorization"
    ]

    /// Pass as `sensitiveHeaders` to record all headers in plaintext — including auth tokens.
    /// Use with caution: HAR files shared via AirDrop or Jira will contain credentials.
    public static let noMasking: Set<String> = []

    private let session: RecordingSession
    private let sensitiveHeaders: Set<String>
    /// Only record requests whose host matches one of these domains (subdomain-aware).
    /// Empty set = record all traffic (default).
    private let allowedDomains: Set<String>
    /// Query parameter names stripped from both the URL string and `queryString` array in HAR.
    /// Use for dynamic values (HMAC signatures, nonces, timestamps) that differ per request.
    private let excludedQueryParams: Set<String>
    private let clock: any RecorderClock

    public init(
        session: RecordingSession,
        sensitiveHeaders: Set<String> = MoyaRecorderPlugin.defaultSensitiveHeaders,
        allowedDomains: Set<String> = [],
        excludedQueryParams: Set<String> = [],
        clock: any RecorderClock = SystemClock()
    ) {
        self.session = session
        self.sensitiveHeaders = sensitiveHeaders
        self.allowedDomains = allowedDomains
        self.excludedQueryParams = excludedQueryParams
        self.clock = clock
    }

    // MARK: - PluginType

    /// Injects the correlation header. Always runs regardless of recording state
    /// to avoid a race where state flips between prepare and willSend.
    public func prepare(_ request: URLRequest, target: TargetType) -> URLRequest {
        var req = request
        if req.value(forHTTPHeaderField: Self.correlationHeader) == nil {
            req.setValue(UUID().uuidString, forHTTPHeaderField: Self.correlationHeader)
        }
        return req
    }

    /// Captures a snapshot of the request and stores it in the pending store.
    /// Runs synchronously on the Moya callback thread — must not await.
    public func willSend(_ request: RequestType, target: TargetType) {
        guard let urlRequest = request.request,
              let reqID = urlRequest.value(forHTTPHeaderField: Self.correlationHeader),
              shouldRecord(url: urlRequest.url)
        else { return }

        let built = HARRequestBuilder.build(
            from: urlRequest,
            moyaTarget: target,
            sensitiveHeaders: sensitiveHeaders,
            excludedQueryParams: excludedQueryParams
        )

        let pendingEntry = PendingEntry(
            requestID: reqID,
            startTime: clock.now(),
            harRequest: built.request,
            httpVersion: "HTTP/1.1",
            bodyByteCount: built.bodyByteCount
        )
        session.pending.insert(pendingEntry)
    }

    /// Completes a HAR entry from the result and schedules an async append to the session.
    /// Runs synchronously on the Moya callback thread — uses `_Concurrency.Task` for the actor hop.
    ///
    /// Correlation strategy:
    /// 1. Extract X-NR-Request-ID from the response request (primary).
    /// 2. For `.underlying(URLError, nil)` — use `URLError.failingURL` to find a pending entry
    ///    by URL (fallback for network-level failures where no response is available).
    /// 3. If still unmatched, the orphan pending entry remains in the store (documented gap).
    public func didReceive(_ result: Result<Response, MoyaError>, target: TargetType) {
        let pendingEntry: PendingEntry?

        if let reqID = Self.extractRequestID(from: result) {
            pendingEntry = session.pending.pop(reqID)
        } else if case .failure(let moyaError) = result,
                  case .underlying(let underlyingError, nil) = moyaError,
                  let urlError = underlyingError as? URLError,
                  let failingURL = urlError.failingURL?.absoluteString {
            // Fallback: match by URL when the request never got a response.
            pendingEntry = session.pending.popByURL(failingURL)
        } else {
            pendingEntry = nil
        }

        guard let pendingEntry else { return }

        let endTime = clock.now()
        let elapsedMs = endTime.timeIntervalSince(pendingEntry.startTime) * 1000.0

        let harResponse: HARResponse
        var entryComment: String? = nil

        switch result {
        case .success(let moyaResponse):
            harResponse = HARResponseBuilder.build(
                from: moyaResponse,
                sensitiveHeaders: sensitiveHeaders
            )
        case .failure(let moyaError):
            let built = HARResponseBuilder.buildError(
                error: moyaError,
                sensitiveHeaders: sensitiveHeaders
            )
            harResponse = built.response
            entryComment = built.comment
        }

        let timings = HARTimings(
            blocked: -1,
            dns: -1,
            connect: -1,
            ssl: -1,
            send: 0,
            wait: elapsedMs,
            receive: 0,
            comment: nil
        )

        let entry = HAREntry(
            startedDateTime: pendingEntry.startTime,
            time: elapsedMs,
            request: pendingEntry.harRequest,
            response: harResponse,
            cache: HARCache(),
            timings: timings,
            serverIPAddress: nil,
            connection: nil,
            comment: entryComment
        )

        let capturedSession = session
        _Concurrency.Task { await capturedSession.append(entry) }
    }

    // MARK: - Private helpers

    /// Returns true if the request URL should be recorded based on `allowedDomains`.
    /// Matches exact host or any subdomain: specifying "example.com" also matches "api.example.com".
    private func shouldRecord(url: URL?) -> Bool {
        guard !allowedDomains.isEmpty else { return true }
        guard let host = url?.host else { return false }
        return allowedDomains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private static func extractRequestID(
        from result: Result<Response, MoyaError>
    ) -> String? {
        switch result {
        case .success(let r):
            return r.request?.value(forHTTPHeaderField: correlationHeader)
        case .failure(let e):
            return e.response?.request?.value(forHTTPHeaderField: correlationHeader)
        }
    }
}
