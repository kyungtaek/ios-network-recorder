// HARCache.swift — Empty cache placeholder required by HAR 1.2 spec.
// Always encodes as `{}` — custom Codable to pin behaviour across Swift versions.

import Foundation

/// HAR 1.2 cache object. Always serialises as an empty JSON object `{}`.
/// The spec requires the `cache` key to be present in every entry.
public struct HARCache: Codable, Equatable {
    public init() {}

    /// Empty key set forces synthesis of no keys, ensuring `{}` on encode.
    private enum CodingKeys: CodingKey {}

    public func encode(to encoder: Encoder) throws {
        // Explicitly open a keyed container so the output is `{}`, not `null`.
        _ = encoder.container(keyedBy: CodingKeys.self)
    }

    public init(from decoder: Decoder) throws {
        // Accept any JSON object (with or without unknown keys).
        _ = try decoder.container(keyedBy: CodingKeys.self)
    }
}
