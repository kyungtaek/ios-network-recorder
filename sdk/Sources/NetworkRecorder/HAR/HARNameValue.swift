// HARNameValue.swift — Generic name/value pair used for headers, queryString, cookies.

import Foundation

/// A name/value pair used in headers, query strings, and cookies.
public struct HARNameValue: Codable, Equatable {
    public var name: String
    public var value: String
    public var comment: String?

    public init(name: String, value: String, comment: String? = nil) {
        self.name = name
        self.value = value
        self.comment = comment
    }
}
