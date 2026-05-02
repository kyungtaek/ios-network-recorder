// HARDateFormatter.swift — Shared ISO8601 formatter with fractional seconds.
// Internal to the module; exposed only via HAR encoding strategy.

import Foundation

enum HARDateFormatter {
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
