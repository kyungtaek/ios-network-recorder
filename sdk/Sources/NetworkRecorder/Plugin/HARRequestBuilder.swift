// HARRequestBuilder.swift — Builds HARRequest from URLRequest + Moya TargetType.
// Internal namespace.

import Foundation
import Moya

/// Internal builder that constructs `HARRequest` from a `URLRequest` and `TargetType`.
enum HARRequestBuilder {
    struct BuildResult {
        let request: HARRequest
        let bodyByteCount: Int
    }

    static func build(
        from urlRequest: URLRequest,
        moyaTarget: TargetType,
        sensitiveHeaders: Set<String>,
        excludedQueryParams: Set<String> = []
    ) -> BuildResult {
        let method = urlRequest.httpMethod ?? "GET"

        // Parse query string from the URL, filtering excluded params from both the
        // queryString array and the URL string stored in the HAR entry.
        var comps = urlRequest.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        let qs: [HARNameValue]
        if excludedQueryParams.isEmpty {
            qs = comps?.queryItems?.map {
                HARNameValue(name: $0.name, value: $0.value ?? "")
            } ?? []
        } else {
            let filtered = comps?.queryItems?.filter {
                !excludedQueryParams.contains($0.name)
            } ?? []
            qs = filtered.map { HARNameValue(name: $0.name, value: $0.value ?? "") }
            // Strip excluded params from the URL string too for a consistent HAR entry.
            comps?.queryItems = filtered.isEmpty ? nil : filtered
        }
        let urlString = comps?.url?.absoluteString ?? urlRequest.url?.absoluteString ?? ""

        // Collect and redact headers.
        let rawHeaders: [(String, String)] = (urlRequest.allHTTPHeaderFields ?? [:])
            .map { ($0.key, $0.value) }
        let headers = HARRedactor.redact(rawHeaders, sensitive: sensitiveHeaders)

        // Body precedence: multipart task → params; httpBody → text; httpBodyStream → sentinel.
        let postData: HARPostData?
        let bodyByteCount: Int

        if let multipart = multipartParams(from: moyaTarget) {
            postData = HARPostData(
                mimeType: urlRequest.value(forHTTPHeaderField: "Content-Type")
                    ?? "multipart/form-data",
                text: nil,
                params: multipart
            )
            bodyByteCount = urlRequest.httpBody?.count ?? -1
        } else if let body = urlRequest.httpBody, !body.isEmpty {
            let mime = urlRequest.value(forHTTPHeaderField: "Content-Type")
                ?? "application/octet-stream"
            let text = String(data: body, encoding: .utf8) ?? "[binary-body]"
            postData = HARPostData(mimeType: mime, text: text, params: nil)
            bodyByteCount = body.count
        } else if urlRequest.httpBodyStream != nil {
            let mime = urlRequest.value(forHTTPHeaderField: "Content-Type")
                ?? "application/octet-stream"
            postData = HARPostData(mimeType: mime, text: "[streaming-body]", params: nil)
            bodyByteCount = -1
        } else {
            postData = nil
            bodyByteCount = 0
        }

        let req = HARRequest(
            method: method,
            url: urlString,
            httpVersion: "HTTP/1.1",
            cookies: [],
            headers: headers,
            queryString: qs,
            postData: postData,
            headersSize: -1,
            bodySize: bodyByteCount,
            comment: nil
        )
        return BuildResult(request: req, bodyByteCount: bodyByteCount)
    }

    /// Inspect Moya Task for multipart payloads. Returns nil if not multipart.
    private static func multipartParams(from target: TargetType) -> [HARParam]? {
        switch target.task {
        case .uploadMultipart(let parts), .uploadCompositeMultipart(let parts, _):
            return parts.map { p in
                let valueHint: String?
                switch p.provider {
                case .data(let d) where d.count < 256:
                    valueHint = String(data: d, encoding: .utf8)
                default:
                    valueHint = "[multipart-part]"
                }
                return HARParam(
                    name: p.name,
                    value: valueHint,
                    fileName: p.fileName,
                    contentType: p.mimeType,
                    comment: nil
                )
            }
        default:
            return nil
        }
    }
}
