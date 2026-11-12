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
        /// Outline per boundary id (only if a member is visible).
        var boundaries: [UUID: BoundaryOutline]
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
        // Every boundary member reserves padding around its subtree inside
        // the subtree layout, so neighbours keep clear of the outline.
        var reservations: [UUID: [Engine.Reservation]] = [:]
        var members: [UUID: [UUID]] = [:]
        for (index, boundary) in map.boundaries.enumerated() {
            let ids = map.normalizedMembers(of: boundary)
            members[boundary.id] = ids
            for id in ids {
                // Fewer members = inner (padded first, enclosed by the others).
                reservations[id, default: []].append(Engine.Reservation(
                    boundaryID: boundary.id, hasLabel: boundary.hasLabel && id == ids.first,
                    rank: ids.count * 100_000 + index))
            }
        }
        let engine = Engine(spacing: spacing, size: size,
                            reservations: reservations.mapValues { $0.sorted { $0.rank < $1.rank } })

        let rootSize = size(map.root.id)
        var all = engine.layoutSubtree(map.root, inherited: .root, isCentral: true)
            .offsetBy(dx: -rootSize.width / 2, dy: -rootSize.height / 2)
        for topic in map.floatingTopics {
            let nodeSize = size(topic.id)
            let local = engine.layoutSubtree(topic.node, inherited: .floating)
            all.merge(local, dx: topic.position.x - nodeSize.width / 2, dy: topic.position.y - nodeSize.height / 2)
        }

        var outlines: [UUID: BoundaryOutline] = [:]
        for boundary in map.boundaries {
            if let outline = outline(of: boundary, members: members[boundary.id] ?? [], map: map, layout: all) {
                outlines[boundary.id] = outline
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
        let bounds = outlines.values.reduce(frameBounds) { $0.union($1.bounds) }
        return Result(frames: all.frames, connectors: all.connectors, boundaries: outlines,
                      relationships: relationshipPaths, bounds: bounds)
    }

    /// Outline over the visible members' pieces (padded subtree areas; free
    /// descendants outside them get their own padded piece) avoiding the
    /// other topics (`BoundaryHull`).
    private func outline(of boundary: Boundary, members: [UUID], map: MindMap,
                         layout: SubtreeLayout) -> BoundaryOutline? {
        var pieces: [CGRect] = []
        var labelPiece = 0
        var enclosed = Set<UUID>()
        for id in members {
            guard let rect = layout.boundaryRects[BoundaryPiece(boundaryID: boundary.id, memberID: id)],
                  let node = map.node(withID: id) else { continue }
            if id == members.first { labelPiece = pieces.count }
            pieces.append(rect)
            for inner in node.allIDs {
                guard let frame = layout.frames[inner] else { continue }
                enclosed.insert(inner)
                if !rect.contains(frame) { pieces.append(padded(frame, hasLabel: false)) }
            }
        }
        guard !pieces.isEmpty else { return nil }
        let obstacles = layout.frames.compactMap { enclosed.contains($0.key) ? nil : $0.value }
        return BoundaryHull.outline(pieces: pieces, labelPiece: labelPiece, obstacles: obstacles)
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
        /// Boundaries a topic is a member of (inner first).
        let reservations: [UUID: [Reservation]]

        struct Reservation {
            var boundaryID: UUID
            /// The label strip goes above this member's piece.
            var hasLabel: Bool
            var rank: Int
        }

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
                avoidObstacles(node, style: context.style, spacing: spacing, in: &layout)
            }
            for reservation in reservations[node.id] ?? [] {
                let rect = TreeLayout(spacing: spacing).padded(layout.bounds, hasLabel: reservation.hasLabel)
                layout.boundaryRects[BoundaryPiece(boundaryID: reservation.boundaryID, memberID: node.id)] = rect
                layout.bounds = layout.bounds.union(rect)
            }
            return layout
        }

        /// Slides the node's auto-laid child subtrees off freely positioned
        /// subtrees (its own manual children and deeper manual topics).
        private func avoidObstacles(_ node: Node, style: LayoutStyle, spacing: LayoutSpacing,
                                    in layout: inout SubtreeLayout) {
            guard !layout.obstacles.isEmpty else { return }
            let stacked = node.children.filter { $0.manualPosition == nil }
            guard !stacked.isEmpty else { return }
            let blocks = stacked.map { child -> ObstacleAvoidance.Block in
                var all = Set<UUID>()
                var auto = CGRect.null
                func visit(_ current: Node, isAuto: Bool) {
                    all.insert(current.id)
                    if isAuto {
                        if let frame = layout.frames[current.id] { auto = auto.union(frame) }
                        for reservation in reservations[current.id] ?? [] {
                            let piece = BoundaryPiece(boundaryID: reservation.boundaryID, memberID: current.id)
                            if let rect = layout.boundaryRects[piece] { auto = auto.union(rect) }
                        }
                    }
                    guard !current.isCollapsed else { return }
                    for kid in current.children { visit(kid, isAuto: isAuto && kid.manualPosition == nil) }
                }
                visit(child, isAuto: true)
                return ObstacleAvoidance.Block(childID: child.id, ids: all, rect: auto)
            }
            let avoidance: ObstacleAvoidance
            switch style {
            case .balancedMap, .rightMap, .leftMap:
                avoidance = ObstacleAvoidance(axis: .vertical, allowsBackward: true, gap: spacing.vertical)
            case .treeDown:
                avoidance = ObstacleAvoidance(axis: .vertical, allowsBackward: false, gap: spacing.vertical)
            case .orgChartDown:
                avoidance = ObstacleAvoidance(axis: .horizontal, allowsBackward: true, gap: spacing.rowGap)
            }
            avoidance.resolve(&layout, nodeID: node.id, blocks: blocks)
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
            let extent = sub.boundaryRects.values.reduce(sub.frames.values.reduce(CGRect.null) { $0.union($1) }) {
                $0.union($1)
            }
            layout.obstacles.append(LayoutObstacle(id: child.id, rect: extent.offsetBy(dx: dx, dy: dy)))
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
