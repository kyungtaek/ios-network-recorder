// HARContent.swift — Response body content per HAR 1.2 spec.

import Foundation

/// Response body content.
public struct HARContent: Codable, Equatable, Sendable {
    /// Size in bytes of the response body. -1 if unknown.
    public var size: Int
    /// MIME type of the response body.
    public var mimeType: String
    /// Body text. nil if binary (see `encoding`).
    public var text: String?
    /// "base64" if `text` contains base64-encoded binary data. nil otherwise (MVP).
    public var encoding: String?
    public var comment: String?

    public init(
        size: Int,
        mimeType: String,
        text: String? = nil,
        encoding: String? = nil,
        comment: String? = nil
    ) {
        self.size = size
        self.mimeType = mimeType
        self.text = text
        self.encoding = encoding
        self.comment = comment
    }
}
