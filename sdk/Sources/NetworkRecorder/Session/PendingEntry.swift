// PendingEntry.swift — Snapshot of a request captured at willSend time.
// Internal implementation detail.

import Foundation

/// Captured state for an in-flight request. Lives in `PendingStore` until
/// the corresponding response arrives in `didReceive`.
struct PendingEntry: Sendable {
    /// Correlation ID injected as X-NR-Request-ID.
    let requestID: String
    /// Wall-clock time when willSend fired; used to compute elapsed ms.
    let startTime: Date
    /// Pre-built, redacted HAR request (built once at willSend time).
    let harRequest: HARRequest
    /// Always "HTTP/1.1" for MVP.
    let httpVersion: String
    /// Body byte count, or -1 if unmeasured.
    let bodyByteCount: Int
}
