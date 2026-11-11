import Foundation

/// Semantic color tag for a node. Views map it to an actual color.
enum ColorTag: String, Codable, CaseIterable {
    case none, red, orange, yellow, green, blue, purple, gray

    /// Unknown raw values (from newer files) decode as `.none`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ColorTag(rawValue: raw) ?? .none
    }
}
