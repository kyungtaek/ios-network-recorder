// HARRedactor.swift — Header masking and correlation-ID stripping.
// Internal namespace.

import Foundation

/// Internal namespace for header redaction logic.
enum HARRedactor {
    /// Replacement value for sensitive header values.
    static let redactedValue = "[REDACTED]"

    /// Default set of headers whose values are masked in HAR output.
    /// Exposed publicly via `MoyaRecorderPlugin.defaultSensitiveHeaders`.
    static let defaultSensitiveHeaders: Set<String> = [
        "Authorization",
        "Cookie",
        "Set-Cookie",
        "Proxy-Authorization"
    ]

    /// Headers stripped entirely from the captured HAR (not masked, removed).
    static let strippedHeaders: Set<String> = [
        MoyaRecorderPlugin.correlationHeader  // "X-NR-Request-ID"
    ]

    /// Redact sensitive headers and strip correlation headers.
    /// Case-insensitive matching for both sensitive and stripped sets.
    ///
    /// - Parameters:
    ///   - headers: Raw header key/value pairs.
    ///   - sensitive: Set of header names whose values should be replaced with `[REDACTED]`.
    /// - Returns: `[HARNameValue]` with sensitive values masked and stripped headers removed.
    static func redact(
        _ headers: [(String, String)],
        sensitive: Set<String>
    ) -> [HARNameValue] {
        let lowerSensitive = Set(sensitive.map { $0.lowercased() })
        let lowerStripped  = Set(strippedHeaders.map { $0.lowercased() })

        return headers.compactMap { (name, value) in
            let lname = name.lowercased()
            if lowerStripped.contains(lname) { return nil }
            let v = lowerSensitive.contains(lname) ? redactedValue : value
            return HARNameValue(name: name, value: v)
        }
    }
}
