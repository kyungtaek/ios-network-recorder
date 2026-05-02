// HAREntry.swift — HAR 1.2 entry object representing one request/response pair.

import Foundation

/// HAR 1.2 entry object. One entry per request/response cycle.
/// `time` MUST equal `timings.send + timings.wait + timings.receive` — upheld at construction.
public struct HAREntry: Codable, Equatable {
    /// When the request started (ISO 8601 with fractional seconds).
    public var startedDateTime: Date
    /// Total elapsed time in milliseconds. Equals send + wait + receive.
    public var time: Double
    public var request: HARRequest
    public var response: HARResponse
    /// Required by HAR 1.2; always encodes as `{}`.
    public var cache: HARCache
    public var timings: HARTimings
    public var serverIPAddress: String?
    public var connection: String?
    /// Error annotation when the response was built from a MoyaError.
    public var comment: String?

    public init(
        startedDateTime: Date,
        time: Double,
        request: HARRequest,
        response: HARResponse,
        cache: HARCache = HARCache(),
        timings: HARTimings,
        serverIPAddress: String? = nil,
        connection: String? = nil,
        comment: String? = nil
    ) {
        self.startedDateTime = startedDateTime
        self.time = time
        self.request = request
        self.response = response
        self.cache = cache
        self.timings = timings
        self.serverIPAddress = serverIPAddress
        self.connection = connection
        self.comment = comment
    }
}
