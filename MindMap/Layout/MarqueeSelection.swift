import CoreGraphics
import Foundation

/// Pure multi-selection rules (XMind-like): toggle, sibling range,
/// rubber-band hits.
enum MarqueeSelection {
    /// Topics whose frame intersects `rect` (map coordinates), in `order`.
    static func hits(in rect: CGRect, frames: [UUID: CGRect], order: [UUID]) -> [UUID] {
        let rect = rect.standardized
        guard rect.width > 0 || rect.height > 0 else { return [] }
        return order.filter { id in frames[id].map { $0.intersects(rect) } ?? false }
    }

    /// Rect spanned by two points.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Siblings from `anchor` to `id` inclusive when both have the same
    /// parent; else nil (the caller just adds `id`).
    static func siblingRange(from anchor: UUID, to id: UUID, in map: MindMap) -> [UUID]? {
        guard anchor != id, let parent = map.parentID(of: anchor), map.parentID(of: id) == parent,
              let siblings = map.node(withID: parent)?.children.map(\.id),
              let from = siblings.firstIndex(of: anchor), let to = siblings.firstIndex(of: id) else { return nil }
        return Array(siblings[min(from, to)...max(from, to)])
    }

    /// New (selection, primary) after toggling `id`: removing the primary
    /// hands the focus to the last remaining topic in `order`.
    static func toggling(_ id: UUID, in selection: Set<UUID>, primary: UUID?,
                         order: [UUID]) -> (selection: Set<UUID>, primary: UUID?) {
        var selection = selection
        if selection.contains(id) {
            selection.remove(id)
            guard primary == id else { return (selection, primary) }
            return (selection, order.last { selection.contains($0) } ?? selection.first)
        }
        selection.insert(id)
        return (selection, id)
    }
}

/// Rubber band being dragged on empty canvas (screen coordinates).
struct MarqueeDrag: Equatable {
    var start: CGPoint
    var current: CGPoint
    /// Selection when the drag began (the band adds to it).
    var base: Set<UUID>
    var basePrimary: UUID?

    var rect: CGRect { MarqueeSelection.rect(from: start, to: current) }
}
