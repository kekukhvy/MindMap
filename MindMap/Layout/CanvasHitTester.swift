import CoreGraphics
import Foundation

/// Selectable thing on the canvas besides topics.
enum CanvasItem: Hashable {
    case relationship(UUID)
    case boundary(UUID)
}

/// Pure hit-testing of a point (map coordinates) against the laid-out map:
/// topics first (their frames), then relationship lines, then boundary
/// outlines / label tabs. Used for secondary clicks; views use the same
/// geometry for their hit shapes.
enum CanvasHitTester {
    enum Hit: Equatable {
        case node(UUID)
        case item(CanvasItem)
    }

    /// Width (map points) of the label tab hit area of a boundary.
    static let boundaryTabWidth: CGFloat = 120

    static func hit(at point: CGPoint, layout: TreeLayout.Result, map: MindMap, tolerance: CGFloat,
                    labelHeight: CGFloat = LayoutSpacing().boundaryLabelHeight) -> Hit? {
        if let node = DropTargetFinder.target(at: point, frames: layout.frames, excluding: []),
           layout.frames[node]?.contains(point) == true {
            return .node(node)
        }
        if let relationship = relationship(at: point, layout: layout, map: map, tolerance: tolerance) {
            return .item(.relationship(relationship))
        }
        // Innermost (smallest) boundary first.
        let boundaries = map.boundaries.compactMap { boundary in layout.boundaries[boundary.id].map { (boundary, $0) } }
            .sorted { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        for (boundary, rect) in boundaries
        where boundaryHits(point, rect: rect, hasLabel: boundary.hasLabel, tolerance: tolerance,
                           labelHeight: labelHeight) {
            return .item(.boundary(boundary.id))
        }
        return nil
    }

    /// Nearest relationship whose line is within `tolerance` of `point`.
    static func relationship(at point: CGPoint, layout: TreeLayout.Result, map: MindMap,
                             tolerance: CGFloat) -> UUID? {
        var best: (UUID, CGFloat)?
        for relationship in map.relationships {
            guard let path = layout.relationships[relationship.id] else { continue }
            let distance = RelationshipCurve.distance(from: point, to: path, style: relationship.style.path)
            if distance <= tolerance, best == nil || distance < best!.1 { best = (relationship.id, distance) }
        }
        return best?.0
    }

    /// Hit on the outline band (inside or outside by `tolerance`) or on the label tab.
    static func boundaryHits(_ point: CGPoint, rect: CGRect, hasLabel: Bool, tolerance: CGFloat,
                             labelHeight: CGFloat) -> Bool {
        let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard outer.contains(point) else { return false }
        let inner = rect.insetBy(dx: tolerance, dy: tolerance)
        if inner.isNull || !inner.contains(point) { return true }
        if hasLabel {
            let tab = CGRect(x: rect.minX, y: rect.minY, width: min(boundaryTabWidth, rect.width), height: labelHeight)
            return tab.contains(point)
        }
        return false
    }
}
