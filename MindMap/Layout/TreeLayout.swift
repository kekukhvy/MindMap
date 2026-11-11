import CoreGraphics
import Foundation

/// Pure layout engine. Recursively lays out each subtree with the arranger
/// of its effective `LayoutStyle` (explicit on the node, else inherited),
/// then places sibling subtrees by their bounding boxes, so subtrees never
/// overlap whatever mix of styles is used.
///
/// Coordinates: the root node's center is at (0, 0); floating topics are
/// centered on their `position`. Collapsed subtrees are omitted.
struct TreeLayout {
    struct Result: Equatable {
        /// Frame of every visible node (main tree and floating topics).
        var frames: [UUID: CGRect]
        /// One connector per visible parent→child edge.
        var connectors: [Connector]
        /// Outline rect per boundary id (only if its node is visible).
        var boundaries: [UUID: CGRect]
        /// Geometry per relationship id (only if both ends are visible).
        var relationships: [UUID: RelationshipPath]
        /// Union of all frames and boundaries.
        var bounds: CGRect
    }

    var spacing: LayoutSpacing

    init(spacing: LayoutSpacing = LayoutSpacing()) {
        self.spacing = spacing
    }

    /// Lays out a bare tree (no map-level items).
    func layout(_ root: Node, size: (UUID) -> CGSize) -> Result {
        layout(MindMap(root: root), size: size)
    }

    /// - Parameter size: node size provider (e.g. measured text + shape padding).
    func layout(_ map: MindMap, size: (UUID) -> CGSize) -> Result {
        withoutActuallyEscaping(size) { layout(map, escapingSize: $0) }
    }

    private func layout(_ map: MindMap, escapingSize size: @escaping (UUID) -> CGSize) -> Result {
        // Single-subtree boundaries reserve space inside the subtree layout,
        // so neighbours keep clear of them.
        let subtreeBoundaries = Dictionary(grouping: map.boundaries.filter { $0.siblingIDs.isEmpty }, by: \.nodeID)
        let engine = Engine(spacing: spacing, size: size, boundaries: subtreeBoundaries)

        let rootSize = size(map.root.id)
        var all = engine.layoutSubtree(map.root, inherited: .root)
            .offsetBy(dx: -rootSize.width / 2, dy: -rootSize.height / 2)
        for topic in map.floatingTopics {
            let nodeSize = size(topic.id)
            let local = engine.layoutSubtree(topic.node, inherited: .floating)
            all.merge(local, dx: topic.position.x - nodeSize.width / 2, dy: topic.position.y - nodeSize.height / 2)
        }

        var boundaryRects = all.boundaryRects
        for boundary in map.boundaries where !boundary.siblingIDs.isEmpty {
            if let rect = rangeBoundaryRect(boundary, map: map, layout: all) {
                boundaryRects[boundary.id] = rect
            }
        }

        var relationshipPaths: [UUID: RelationshipPath] = [:]
        for relationship in map.relationships {
            guard let from = all.frames[relationship.fromNodeID], let to = all.frames[relationship.toNodeID] else {
                continue
            }
            relationshipPaths[relationship.id] = RelationshipGeometry.path(from: from, to: to, relationship: relationship)
        }

        let bounds = boundaryRects.values.reduce(all.bounds) { $0.union($1) }
        return Result(frames: all.frames, connectors: all.connectors, boundaries: boundaryRects,
                      relationships: relationshipPaths, bounds: bounds)
    }

    /// Boundary over several sibling subtrees: union of their visible frames
    /// and nested boundaries, plus padding (not reserved in spacing).
    private func rangeBoundaryRect(_ boundary: Boundary, map: MindMap, layout: SubtreeLayout) -> CGRect? {
        guard layout.frames[boundary.nodeID] != nil else { return nil }
        var ids = Set<UUID>()
        for rootID in boundary.enclosedRootIDs {
            if let node = map.node(withID: rootID) { ids.formUnion(node.allIDs) }
        }
        var rect: CGRect?
        for id in ids {
            if let frame = layout.frames[id] { rect = rect?.union(frame) ?? frame }
        }
        for inner in map.boundaries where inner.id != boundary.id && ids.contains(inner.nodeID) {
            if let innerRect = layout.boundaryRects[inner.id] { rect = rect?.union(innerRect) ?? innerRect }
        }
        return rect.map { padded($0, hasLabel: boundary.hasLabel) }
    }

    fileprivate func padded(_ rect: CGRect, hasLabel: Bool) -> CGRect {
        var result = rect.insetBy(dx: -spacing.boundaryPadding, dy: -spacing.boundaryPadding)
        if hasLabel {
            result.origin.y -= spacing.boundaryLabelHeight
            result.size.height += spacing.boundaryLabelHeight
        }
        return result
    }

    private struct Engine {
        let spacing: LayoutSpacing
        let size: (UUID) -> CGSize
        let boundaries: [UUID: [Boundary]]

        func layoutSubtree(_ node: Node, inherited: LayoutContext) -> SubtreeLayout {
            let nodeSize = size(node.id)
            var layout: SubtreeLayout
            if node.isCollapsed || node.children.isEmpty {
                layout = SubtreeLayout(id: node.id, size: nodeSize)
            } else {
                let context = inherited.resolved(for: node)
                layout = Arrangers.arranger(for: context.style).arrange(
                    node,
                    nodeSize: nodeSize,
                    context: context,
                    spacing: spacing,
                    layoutChild: { child, childContext in
                        layoutSubtree(child, inherited: childContext)
                    }
                )
            }
            for boundary in boundaries[node.id] ?? [] {
                let rect = TreeLayout(spacing: spacing).padded(layout.bounds, hasLabel: boundary.hasLabel)
                layout.boundaryRects[boundary.id] = rect
                layout.bounds = layout.bounds.union(rect)
            }
            return layout
        }
    }
}
