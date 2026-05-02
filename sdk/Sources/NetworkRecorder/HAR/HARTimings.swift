// HARTimings.swift — Request/response timing breakdown per HAR 1.2 spec.

import Foundation

/// HAR 1.2 timings object. Unmeasured fields use -1 as the sentinel value.
/// send + wait + receive == HAREntry.time (invariant upheld at construction site).
public struct HARTimings: Codable, Equatable {
    /// Time spent in a queue waiting for a network connection (-1 = not measured).
    public var blocked: Double
    /// DNS resolution time (-1 = not measured).
    public var dns: Double
    /// TCP connection time (-1 = not measured).
    public var connect: Double
    /// SSL/TLS handshake time (-1 = not measured).
    public var ssl: Double
    /// Time to send the request. Moya cannot measure separately; always 0.
    public var send: Double
    /// Time waiting for the first byte (wall-clock elapsed rounded to ms).
    public var wait: Double
    /// Time to read the response. Moya cannot measure separately; always 0.
    public var receive: Double
    public var comment: String?

    public init(
        blocked: Double = -1,
        dns: Double = -1,
        connect: Double = -1,
        ssl: Double = -1,
        send: Double,
        wait: Double,
        receive: Double,
        comment: String? = nil
    ) {
        self.blocked = blocked
        self.dns = dns
        self.connect = connect
        self.ssl = ssl
        self.send = send
        self.wait = wait
        self.receive = receive
        self.comment = comment
    }
}
