import Foundation

/// Visual topic shape. `nil` on a node = default by depth (`defaultShape(forDepth:)`).
enum NodeShape: String, Codable, CaseIterable {
    case roundedRect, rectangle, capsule, underline, plainText

    /// XMind (pastel) defaults: central topic = plain bold text, main topics
    /// (filled) and level-2 subtopics (pale tint) = rounded rect, deeper
    /// levels = plain text.
    static func defaultShape(forDepth depth: Int) -> NodeShape {
        switch depth {
        case 0: return .plainText
        case 1, 2: return .roundedRect
        default: return .plainText
        }
    }
}

/// Topic border line style. `nil` on a node = `.solid`.
enum BorderStyle: String, Codable, CaseIterable {
    case solid, dashed
}
