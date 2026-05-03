// HARResponseBuilder.swift — Builds HARResponse from Moya Response or MoyaError.
// Internal namespace.

import Foundation
@preconcurrency import Moya

/// Internal builder that constructs `HARResponse` from a Moya `Response` or `MoyaError`.
enum HARResponseBuilder {
    struct ErrorBuild {
        let response: HARResponse
        let comment: String
    }

    /// Build a `HARResponse` from a successful Moya `Response`.
    static func build(
        from response: Response,
        sensitiveHeaders: Set<String>
    ) -> HARResponse {
        let http = response.response
        let status = response.statusCode
        let statusText = http.map {
            HTTPURLResponse.localizedString(forStatusCode: $0.statusCode)
        } ?? ""

        // Cast HTTPURLResponse allHeaderFields — keys and values are Strings in practice.
        var rawHeaders: [(String, String)] = []
        if let httpResponse = http {
            for (key, value) in httpResponse.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    rawHeaders.append((k, v))
                }
            }
        }
        let headers = HARRedactor.redact(rawHeaders, sensitive: sensitiveHeaders)

        let mime = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let bodyText = String(data: response.data, encoding: .utf8)
        let isBinary = bodyText == nil && !response.data.isEmpty
        let content = HARContent(
            size: response.data.count,
            mimeType: mime,
            text: isBinary ? response.data.base64EncodedString() : bodyText,
            encoding: isBinary ? "base64" : nil,
            comment: nil
        )

        return HARResponse(
            status: status,
            statusText: statusText,
            httpVersion: "HTTP/1.1",
            cookies: [],
            headers: headers,
            content: content,
            redirectURL: http?.value(forHTTPHeaderField: "Location") ?? "",
            headersSize: -1,
            bodySize: response.data.count,
            comment: nil
        )
    }

    /// Build a `HARResponse` from a `MoyaError`. Never returns nil — always writes an entry.
    ///
    /// - If the error carries a `Response`, the real status/headers/body are used with a
    ///   comment annotating the error case.
    /// - Otherwise, a stub with `status=0` is returned.
    static func buildError(
        error: MoyaError,
        sensitiveHeaders: Set<String>
    ) -> ErrorBuild {
        // Extract a short case label from the error.
        let caseLabel: String
        switch error {
        case .imageMapping:      caseLabel = "imageMapping"
        case .jsonMapping:       caseLabel = "jsonMapping"
        case .stringMapping:     caseLabel = "stringMapping"
        case .objectMapping:     caseLabel = "objectMapping"
        case .encodableMapping:  caseLabel = "encodableMapping"
        case .statusCode:        caseLabel = "statusCode"
        case .underlying:        caseLabel = "underlying"
        case .requestMapping:    caseLabel = "requestMapping"
        case .parameterEncoding: caseLabel = "parameterEncoding"
        @unknown default:        caseLabel = "moyaError"
        }

        if let resp = error.response {
            let real = build(from: resp, sensitiveHeaders: sensitiveHeaders)
            return ErrorBuild(response: real, comment: "moya-error: \(caseLabel)")
        }

        let stub = HARResponse(
            status: 0,
            statusText: caseLabel,
            httpVersion: "HTTP/1.1",
            cookies: [],
            headers: [],
            content: HARContent(
                size: 0,
                mimeType: "application/octet-stream",
                text: nil,
                encoding: nil,
                comment: nil
            ),
            redirectURL: "",
            headersSize: -1,
            bodySize: -1,
            comment: nil
        )
        return ErrorBuild(response: stub, comment: "moya-error: \(caseLabel)")
    }
}
