import CoreGraphics
import Foundation

/// Layout of one subtree in local coordinates: the subtree's own node frame
/// has its origin at (0, 0). `bounds` is the union of all node frames and
/// boundary outlines inside it.
struct SubtreeLayout {
    var frames: [UUID: CGRect]
    var connectors: [Connector]
    /// Boundary outlines by boundary id.
    var boundaryRects: [UUID: CGRect]
    var bounds: CGRect

    init(id: UUID, size: CGSize) {
        let frame = CGRect(origin: .zero, size: size)
        frames = [id: frame]
        connectors = []
        boundaryRects = [:]
        bounds = frame
    }

    /// Adds `child` translated by (dx, dy); `unionBounds: false` keeps it
    /// out of `bounds` (freely positioned subtrees).
    mutating func merge(_ child: SubtreeLayout, dx: CGFloat, dy: CGFloat, unionBounds: Bool = true) {
        for (id, frame) in child.frames {
            frames[id] = frame.offsetBy(dx: dx, dy: dy)
        }
        for (id, rect) in child.boundaryRects {
            boundaryRects[id] = rect.offsetBy(dx: dx, dy: dy)
        }
        connectors += child.connectors.map { $0.offsetBy(dx: dx, dy: dy) }
        if unionBounds { bounds = bounds.union(child.bounds.offsetBy(dx: dx, dy: dy)) }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> SubtreeLayout {
        var copy = self
        copy.frames = frames.mapValues { $0.offsetBy(dx: dx, dy: dy) }
        copy.boundaryRects = boundaryRects.mapValues { $0.offsetBy(dx: dx, dy: dy) }
        copy.connectors = connectors.map { $0.offsetBy(dx: dx, dy: dy) }
        copy.bounds = bounds.offsetBy(dx: dx, dy: dy)
        return copy
    }
}

/// A laid-out child subtree waiting to be placed by its parent's arranger.
struct ChildSubtree {
    var id: UUID
    var layout: SubtreeLayout
    var nodeFrame: CGRect { layout.frames[id] ?? .zero }
}
