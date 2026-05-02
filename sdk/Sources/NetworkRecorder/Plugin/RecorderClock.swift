// RecorderClock.swift — Abstraction over wall-clock time for testability.

import Foundation

/// Protocol for obtaining the current time. Injected into `MoyaRecorderPlugin`
/// to allow tests to control timing without sleeping.
public protocol RecorderClock: Sendable {
    func now() -> Date
}

/// Default clock implementation using `Date()`.
public struct SystemClock: RecorderClock {
    public init() {}
    public func now() -> Date { Date() }
}
