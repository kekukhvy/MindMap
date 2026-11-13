import CoreGraphics
import Foundation

/// Layout of one subtree in local coordinates: the subtree's own node frame
/// has its origin at (0, 0). `bounds` is the union of all node frames and
/// boundary outlines inside it.
struct SubtreeLayout {
    var frames: [UUID: CGRect]
    var connectors: [Connector]
    /// Padded area of each boundary member's subtree (one piece per
    /// boundary and member; `BoundaryHull` joins a boundary's pieces).
    var boundaryRects: [BoundaryPiece: CGRect]
    var bounds: CGRect
    /// Extents of freely positioned subtrees inside this one (not in
    /// `bounds`): auto-laid sibling subtrees at every ancestor level are
    /// shifted out of their way (`ObstacleAvoidance`).
    var obstacles: [LayoutObstacle]
    /// Side split of every balanced-map node inside (position-independent).
    var balanced: [UUID: BalancedSplit] = [:]

    init(id: UUID, size: CGSize) {
        let frame = CGRect(origin: .zero, size: size)
        frames = [id: frame]
        connectors = []
        boundaryRects = [:]
        bounds = frame
        obstacles = []
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
        obstacles += child.obstacles.map { $0.offsetBy(dx: dx, dy: dy) }
        balanced.merge(child.balanced) { current, _ in current }
        if unionBounds { bounds = bounds.union(child.bounds.offsetBy(dx: dx, dy: dy)) }
    }

    /// Everything drawn: frames, boundary pieces and free subtrees.
    var extent: CGRect {
        let frames = self.frames.values.reduce(bounds) { $0.union($1) }
        let pieces = boundaryRects.values.reduce(frames) { $0.union($1) }
        return obstacles.reduce(pieces) { $0.union($1.rect) }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> SubtreeLayout {
        var copy = self
        copy.frames = frames.mapValues { $0.offsetBy(dx: dx, dy: dy) }
        copy.boundaryRects = boundaryRects.mapValues { $0.offsetBy(dx: dx, dy: dy) }
        copy.connectors = connectors.map { $0.offsetBy(dx: dx, dy: dy) }
        copy.obstacles = obstacles.map { $0.offsetBy(dx: dx, dy: dy) }
        copy.bounds = bounds.offsetBy(dx: dx, dy: dy)
        return copy
    }
}

/// One member of one boundary (key of its padded subtree area).
struct BoundaryPiece: Hashable {
    var boundaryID: UUID
    var memberID: UUID
}

/// A laid-out child subtree waiting to be placed by its parent's arranger.
struct ChildSubtree {
    var id: UUID
    var layout: SubtreeLayout
    var nodeFrame: CGRect { layout.frames[id] ?? .zero }
}

/// Area taken by a freely positioned subtree (`id` = its root topic).
struct LayoutObstacle: Equatable {
    var id: UUID
    var rect: CGRect

    func offsetBy(dx: CGFloat, dy: CGFloat) -> LayoutObstacle {
        LayoutObstacle(id: id, rect: rect.offsetBy(dx: dx, dy: dy))
    }
}
