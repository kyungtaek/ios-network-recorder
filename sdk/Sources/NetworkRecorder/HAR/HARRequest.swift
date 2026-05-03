// HARRequest.swift — HAR 1.2 request object.

import Foundation

/// HAR 1.2 request object capturing all details of an outgoing HTTP request.
public struct HARRequest: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    /// HTTP version string. Hard-coded "HTTP/1.1" for MVP.
    public var httpVersion: String
    /// MVP: always empty — cookie parsing is out of scope.
    public var cookies: [HARNameValue]
    public var headers: [HARNameValue]
    public var queryString: [HARNameValue]
    /// Request body. nil when no body.
    public var postData: HARPostData?
    /// -1 (not measured).
    public var headersSize: Int
    /// Body byte count if known; -1 if unknown.
    public var bodySize: Int
    public var comment: String?

    public init(
        method: String,
        url: String,
        httpVersion: String = "HTTP/1.1",
        cookies: [HARNameValue] = [],
        headers: [HARNameValue],
        queryString: [HARNameValue],
        postData: HARPostData? = nil,
        headersSize: Int = -1,
        bodySize: Int,
        comment: String? = nil
    ) {
        self.method = method
        self.url = url
        self.httpVersion = httpVersion
        self.cookies = cookies
        self.headers = headers
        self.queryString = queryString
        self.postData = postData
        self.headersSize = headersSize
        self.bodySize = bodySize
        self.comment = comment
    }
}
