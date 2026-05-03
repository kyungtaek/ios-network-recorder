// HARResponse.swift — HAR 1.2 response object.

import Foundation

/// HAR 1.2 response object. status=0 is used for error stubs (request never sent).
public struct HARResponse: Codable, Equatable, Sendable {
    /// HTTP status code. 0 indicates the request never reached the server.
    public var status: Int
    /// HTTP reason phrase, or MoyaError case name for error stubs.
    public var statusText: String
    /// HTTP version string. Hard-coded "HTTP/1.1" for MVP.
    public var httpVersion: String
    /// MVP: always empty — cookie parsing is out of scope.
    public var cookies: [HARNameValue]
    public var headers: [HARNameValue]
    public var content: HARContent
    /// Redirect URL, or "" when none. HAR 1.2 requires this key.
    public var redirectURL: String
    /// -1 (not measured).
    public var headersSize: Int
    /// Body byte count if known; -1 if unknown.
    public var bodySize: Int
    public var comment: String?

    public init(
        status: Int,
        statusText: String,
        httpVersion: String = "HTTP/1.1",
        cookies: [HARNameValue] = [],
        headers: [HARNameValue],
        content: HARContent,
        redirectURL: String = "",
        headersSize: Int = -1,
        bodySize: Int,
        comment: String? = nil
    ) {
        self.status = status
        self.statusText = statusText
        self.httpVersion = httpVersion
        self.cookies = cookies
        self.headers = headers
        self.content = content
        self.redirectURL = redirectURL
        self.headersSize = headersSize
        self.bodySize = bodySize
        self.comment = comment
    }
}
