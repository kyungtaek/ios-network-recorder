// HARPostData.swift — Request body capture per HAR 1.2 spec.

import Foundation

/// Captured request body. Exactly one of `text` or `params` should be non-nil.
/// `mimeType` is required by HAR 1.2; defaults to "application/octet-stream".
public struct HARPostData: Codable, Equatable {
    /// MIME type of the posted data. Required by HAR 1.2.
    public var mimeType: String
    /// Raw body text, or "[streaming-body]" for streams, or nil if params is used.
    public var text: String?
    /// Multipart form parameters, or nil if text is used.
    public var params: [HARParam]?
    public var comment: String?

    public init(
        mimeType: String,
        text: String? = nil,
        params: [HARParam]? = nil,
        comment: String? = nil
    ) {
        self.mimeType = mimeType
        self.text = text
        self.params = params
        self.comment = comment
    }
}

/// A single multipart form field.
public struct HARParam: Codable, Equatable {
    public var name: String
    public var value: String?
    public var fileName: String?
    public var contentType: String?
    public var comment: String?

    public init(
        name: String,
        value: String? = nil,
        fileName: String? = nil,
        contentType: String? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.value = value
        self.fileName = fileName
        self.contentType = contentType
        self.comment = comment
    }
}
