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
/// Sensitive headers (Authorization, Cookie, etc.) are masked with `[REDACTED]`.
public final class MoyaRecorderPlugin: PluginType {
    /// Name of the internal correlation header injected into every request.
    public static let correlationHeader = "X-NR-Request-ID"

    /// Default set of header names whose values are replaced with `[REDACTED]` in HAR output.
    /// Deviation from design (where it lived on `HARRedactor`): moved here so the value
    /// is accessible as a public API default argument. `HARRedactor` remains internal.
    public static let defaultSensitiveHeaders: Set<String> = [
        "Authorization",
        "Cookie",
        "Set-Cookie",
        "Proxy-Authorization"
    ]

    private let session: RecordingSession
    private let sensitiveHeaders: Set<String>
    private let clock: any RecorderClock

    public init(
        session: RecordingSession,
        sensitiveHeaders: Set<String> = MoyaRecorderPlugin.defaultSensitiveHeaders,
        clock: any RecorderClock = SystemClock()
    ) {
        self.session = session
        self.sensitiveHeaders = sensitiveHeaders
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
              let reqID = urlRequest.value(forHTTPHeaderField: Self.correlationHeader)
        else { return }

        let built = HARRequestBuilder.build(
            from: urlRequest,
            moyaTarget: target,
            sensitiveHeaders: sensitiveHeaders
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
