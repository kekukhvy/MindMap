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
        var all = engine.layoutSubtree(map.root, inherited: .root, isCentral: true)
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

        // Freely positioned subtrees are not in the stacking bounds.
        let frameBounds = all.frames.values.reduce(all.bounds) { $0.union($1) }
        let bounds = boundaryRects.values.reduce(frameBounds) { $0.union($1) }
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

        /// - Parameter isCentral: the main tree's root (uses the wider root gaps).
        func layoutSubtree(_ node: Node, inherited: LayoutContext, isCentral: Bool = false) -> SubtreeLayout {
            let nodeSize = size(node.id)
            let spacing = isCentral ? self.spacing.forCentralTopic : self.spacing
            var layout: SubtreeLayout
            // Freely positioned children leave the automatic stacking.
            var stacked = node
            stacked.children = node.children.filter { $0.manualPosition == nil }
            if node.isCollapsed || stacked.children.isEmpty {
                layout = SubtreeLayout(id: node.id, size: nodeSize)
            } else {
                let context = inherited.resolved(for: node)
                layout = Arrangers.arranger(for: context.style).arrange(
                    stacked,
                    nodeSize: nodeSize,
                    context: context,
                    spacing: spacing,
                    layoutChild: { child, childContext in
                        layoutSubtree(child, inherited: childContext)
                    }
                )
            }
            if !node.isCollapsed {
                let context = inherited.resolved(for: node)
                for child in node.children {
                    if let offset = child.manualPosition {
                        placeManual(child, offset: offset, parentID: node.id, parentSize: nodeSize,
                                    context: context, into: &layout)
                    }
                }
            }
            for boundary in boundaries[node.id] ?? [] {
                let rect = TreeLayout(spacing: spacing).padded(layout.bounds, hasLabel: boundary.hasLabel)
                layout.boundaryRects[boundary.id] = rect
                layout.bounds = layout.bounds.union(rect)
            }
            return layout
        }

        /// Places a freely positioned child subtree with its node centered at
        /// `offset` from the parent's center. Its own subtree is laid out
        /// automatically, growing away from the parent (left of the parent =
        /// left-growing). It does not count in the parent's stacking bounds,
        /// so siblings re-flow without it and ancestors ignore it.
        private func placeManual(_ child: Node, offset: CGPoint, parentID: UUID, parentSize: CGSize,
                                 context: LayoutContext, into layout: inout SubtreeLayout) {
            let side: HorizontalDirection = offset.x < 0 ? .left : .right
            let childContext: LayoutContext
            switch context.style {
            case .balancedMap, .rightMap, .leftMap: childContext = context.horizontal(side)
            case .treeDown, .orgChartDown: childContext = context.passingDown(style: context.style, direction: side)
            }
            let sub = layoutSubtree(child, inherited: childContext)
            let childSize = size(child.id)
            let dx = parentSize.width / 2 + offset.x - childSize.width / 2
            let dy = parentSize.height / 2 + offset.y - childSize.height / 2
            layout.merge(sub, dx: dx, dy: dy, unionBounds: false)
            let frame = CGRect(origin: CGPoint(x: dx, y: dy), size: childSize)
            let parent = CGRect(origin: .zero, size: parentSize)
            let start: CGPoint, end: CGPoint, axis: ConnectorAxis
            if frame.minX >= parent.maxX || frame.maxX <= parent.minX {
                axis = .horizontal
                start = CGPoint(x: side == .right ? parent.maxX : parent.minX, y: parent.midY)
                end = CGPoint(x: side == .right ? frame.minX : frame.maxX, y: frame.midY)
            } else {
                axis = .vertical
                let below = frame.midY > parent.midY
                start = CGPoint(x: parent.midX, y: below ? parent.maxY : parent.minY)
                end = CGPoint(x: frame.midX, y: below ? frame.minY : frame.maxY)
            }
            layout.connectors.append(context.connector(from: parentID, to: child.id, start: start, end: end,
                                                       axes: (axis, axis), defaultStyle: .curved))
        }
    }
}
