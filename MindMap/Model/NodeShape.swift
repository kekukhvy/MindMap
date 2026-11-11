import Foundation

/// Visual topic shape. `nil` on a node = default by depth (`defaultShape(forDepth:)`).
enum NodeShape: String, Codable, CaseIterable {
    case roundedRect, rectangle, capsule, underline, plainText

    /// XMind-like defaults: root and level 1 = rounded rect (views render
    /// root bold, level 1 filled), deeper levels = underline.
    static func defaultShape(forDepth depth: Int) -> NodeShape {
        depth <= 1 ? .roundedRect : .underline
    }
}

/// Topic border line style. `nil` on a node = `.solid`.
enum BorderStyle: String, Codable, CaseIterable {
    case solid, dashed
}
