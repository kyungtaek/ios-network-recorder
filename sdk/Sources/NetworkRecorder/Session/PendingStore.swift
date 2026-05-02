// PendingStore.swift — Thread-safe dictionary of in-flight requests.
// Internal implementation detail. Uses NSLock for synchronous access
// from Moya plugin callbacks (which run on arbitrary threads, not the actor).

import Foundation

/// Synchronous, NSLock-protected map from correlation ID → PendingEntry.
/// Must be `@unchecked Sendable` because NSLock manages its own thread safety.
final class PendingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: PendingEntry] = [:]
    private var insertionOrder: [String] = []

    func insert(_ entry: PendingEntry) {
        lock.lock()
        defer { lock.unlock() }
        map[entry.requestID] = entry
        insertionOrder.append(entry.requestID)
    }

    func pop(_ requestID: String) -> PendingEntry? {
        lock.lock()
        defer { lock.unlock() }
        insertionOrder.removeAll { $0 == requestID }
        return map.removeValue(forKey: requestID)
    }

    /// Pop the first pending entry whose `harRequest.url` matches `url`.
    /// Used for correlating `URLError.underlying(_, nil)` failures where no
    /// request ID is available from the result.
    /// Respects insertion order (FIFO) for same-base-URL requests.
    func popByURL(_ url: String) -> PendingEntry? {
        lock.lock()
        defer { lock.unlock() }
        // Strip query string for matching (URLError.failingURL may omit query params).
        let baseURL = url.components(separatedBy: "?").first ?? url
        guard let key = insertionOrder.first(where: {
            let entryBase = map[$0]?.harRequest.url.components(separatedBy: "?").first ?? ""
            return entryBase == baseURL
        }) else { return nil }
        insertionOrder.removeAll { $0 == key }
        return map.removeValue(forKey: key)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        map.removeAll()
        insertionOrder.removeAll()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return map.count
    }
}
