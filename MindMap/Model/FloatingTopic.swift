import CoreGraphics
import Foundation

/// A free-positioned topic (with its own subtree) outside the main tree.
/// Its children are laid out by its layoutStyle (default `.rightMap`).
struct FloatingTopic: Identifiable, Equatable, Codable {
    var node: Node
    /// Center of the floating topic's node, in map coordinates (root center = origin).
    var position: CGPoint

    var id: UUID { node.id }
}
