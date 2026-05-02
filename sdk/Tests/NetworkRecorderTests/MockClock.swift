// MockClock.swift — Test-only clock that allows controlled time advancement.

import Foundation
@testable import NetworkRecorder

/// A clock whose current time can be set explicitly.
/// Use `nowDate` to simulate request start, then advance before calling didReceive.
final class MockClock: RecorderClock, @unchecked Sendable {
    var nowDate: Date

    init(date: Date = Date()) {
        self.nowDate = date
    }

    func now() -> Date { nowDate }
}
