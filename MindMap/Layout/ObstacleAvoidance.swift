import CoreGraphics
import Foundation

/// Keeps a node's auto-laid child subtrees clear of freely positioned
/// subtrees (`LayoutObstacle`s: its own manual children and manual topics
/// deeper inside its other children). The manual subtrees stay where the
/// user put them; whole auto-laid sibling subtrees ("blocks") slide along
/// their stacking axis instead: blocks before an obstacle's middle move
/// back (up / left), the others forward, keeping their order and gaps.
struct ObstacleAvoidance {
    enum Axis {
        /// Blocks stacked top to bottom (map / logic / tree styles).
        case vertical
        /// Blocks side by side (org chart).
        case horizontal
    }

    /// One auto-laid child subtree of the node.
    struct Block {
        var childID: UUID
        /// Every visible topic of the subtree (manual descendants included:
        /// they move with it).
        var ids: Set<UUID>
        /// Area of its auto-laid part (frames + subtree boundaries).
        var rect: CGRect
    }

    var axis: Axis
    /// Blocks may move up / left (tree charts only grow away from the parent).
    var allowsBackward: Bool
    var gap: CGFloat

    /// Moves blocks of `layout` (node frame at the origin) off obstacles.
    /// Boundary pieces move with their member. Returns true if any moved.
    @discardableResult
    func resolve(_ layout: inout SubtreeLayout, nodeID: UUID, blocks: [Block]) -> Bool {
        guard !layout.obstacles.isEmpty, !blocks.isEmpty else { return false }
        let nodeFrame = layout.frames[nodeID] ?? .zero
        // Columns: left / right of the node for vertical stacking.
        var columns: [[Block]] = []
        if axis == .vertical {
            let left = blocks.filter { $0.rect.maxX <= nodeFrame.minX + 0.5 }
            let leftIDs = Set(left.map(\.childID))
            columns = [left, blocks.filter { !leftIDs.contains($0.childID) }]
        } else {
            columns = [blocks]
        }
        var moved = false
        var bounds = nodeFrame
        for column in columns where !column.isEmpty {
            // Stable order (ties keep document order): same input, same result.
            let ordered = column.enumerated().sorted {
                (lo($0.element.rect), $0.offset) < (lo($1.element.rect), $1.offset)
            }.map(\.element)
            let shifts = shifts(for: ordered, obstacles: layout.obstacles)
            for (block, delta) in shifts {
                bounds = bounds.union(offset(block.rect, delta))
                guard abs(delta) > 0.001 else { continue }
                apply(delta, to: block, layout: &layout)
                moved = true
            }
        }
        if moved { layout.bounds = bounds }
        return moved
    }

    // MARK: Sweep

    /// New offsets along the axis for an ordered column of blocks.
    private func shifts(for column: [Block], obstacles: [LayoutObstacle]) -> [(Block, CGFloat)] {
        var rects = column.map(\.rect)
        var obstacles = obstacles
        func blocking(_ index: Int) -> [Int] {
            obstacles.indices.filter { !column[index].ids.contains(obstacles[$0].id) }
        }
        // Last block that should pass in front of (above) an obstacle.
        var lastBackward = -1
        if allowsBackward {
            for index in column.indices {
                for o in blocking(index) where hits(rects[index], obstacles[o].rect)
                    && mid(rects[index]) < mid(obstacles[o].rect) {
                    lastBackward = index
                }
            }
        }
        var deltas = Array(repeating: CGFloat(0), count: column.count)
        func move(_ index: Int, to start: CGFloat) {
            let delta = start - lo(rects[index])
            guard delta != 0 else { return }
            deltas[index] += delta
            rects[index] = offset(rects[index], delta)
            // Manual topics inside the block move with it.
            for o in obstacles.indices where column[index].ids.contains(obstacles[o].id) {
                obstacles[o].rect = offset(obstacles[o].rect, delta)
            }
        }
        func owned(_ index: Int) -> [Int] {
            obstacles.indices.filter { column[index].ids.contains(obstacles[$0].id) }
        }
        // Forward sweep (down / right). A block must clear foreign obstacles,
        // and the free topics inside it (which move with it) must clear the
        // blocks before it.
        for index in column.indices where index > lastBackward {
            var start = lo(rects[index])
            if index > 0 { start = max(start, hi(rects[index - 1]) + gap) }
            for _ in 0..<1000 {
                let delta = start - lo(rects[index])
                let candidate = offset(rects[index], delta)
                if let o = blocking(index).first(where: { hits(candidate, obstacles[$0].rect) }) {
                    start = hi(obstacles[o].rect) + gap
                    continue
                }
                let conflict = owned(index).lazy.compactMap { o -> CGFloat? in
                    let moved = offset(obstacles[o].rect, delta)
                    if let k = (0..<index).first(where: { hits(rects[$0], moved) }) {
                        return hi(rects[k]) + gap - lo(moved)
                    }
                    // A free topic inside the block must clear foreign free topics.
                    guard let f = blocking(index).first(where: { hits(moved, obstacles[$0].rect) }) else { return nil }
                    return hi(obstacles[f].rect) + gap - lo(moved)
                }.first
                guard let push = conflict else { break }
                start += max(push, 0.5)
            }
            move(index, to: start)
        }
        // Backward sweep (up / left), mirrored.
        for index in stride(from: lastBackward, through: 0, by: -1) {
            let length = hi(rects[index]) - lo(rects[index])
            var end = hi(rects[index])
            if index + 1 < column.count { end = min(end, lo(rects[index + 1]) - gap) }
            for _ in 0..<1000 {
                let delta = end - hi(rects[index])
                let candidate = offset(rects[index], delta)
                if let o = blocking(index).first(where: { hits(candidate, obstacles[$0].rect) }) {
                    end = lo(obstacles[o].rect) - gap
                    continue
                }
                let conflict = owned(index).lazy.compactMap { o -> CGFloat? in
                    let moved = offset(obstacles[o].rect, delta)
                    if let k = (index + 1..<column.count).first(where: { hits(rects[$0], moved) }) {
                        return hi(moved) - (lo(rects[k]) - gap)
                    }
                    guard let f = blocking(index).first(where: { hits(moved, obstacles[$0].rect) }) else { return nil }
                    return hi(moved) - (lo(obstacles[f].rect) - gap)
                }.first
                guard let pull = conflict else { break }
                end -= max(pull, 0.5)
            }
            move(index, to: end - length)
        }
        return Array(zip(column, deltas))
    }

    /// Overlap including the gap on the stacking axis (the cross axis needs
    /// a real overlap: a block beside an obstacle may stay level with it).
    private func hits(_ rect: CGRect, _ obstacle: CGRect) -> Bool {
        let crossOverlap: Bool
        switch axis {
        case .vertical: crossOverlap = rect.minX < obstacle.maxX + gap / 2 && obstacle.minX - gap / 2 < rect.maxX
        case .horizontal: crossOverlap = rect.minY < obstacle.maxY + gap / 2 && obstacle.minY - gap / 2 < rect.maxY
        }
        return crossOverlap && lo(rect) < hi(obstacle) + gap - 0.001 && lo(obstacle) - gap + 0.001 < hi(rect)
    }

    private func lo(_ rect: CGRect) -> CGFloat { axis == .vertical ? rect.minY : rect.minX }
    private func hi(_ rect: CGRect) -> CGFloat { axis == .vertical ? rect.maxY : rect.maxX }
    private func mid(_ rect: CGRect) -> CGFloat { axis == .vertical ? rect.midY : rect.midX }
    private func offset(_ rect: CGRect, _ delta: CGFloat) -> CGRect {
        axis == .vertical ? rect.offsetBy(dx: 0, dy: delta) : rect.offsetBy(dx: delta, dy: 0)
    }

    // MARK: Applying

    private func apply(_ delta: CGFloat, to block: Block, layout: inout SubtreeLayout) {
        let dx = axis == .horizontal ? delta : 0
        let dy = axis == .vertical ? delta : 0
        for id in block.ids {
            layout.frames[id] = layout.frames[id]?.offsetBy(dx: dx, dy: dy)
        }
        for index in layout.connectors.indices where block.ids.contains(layout.connectors[index].childID) {
            if block.ids.contains(layout.connectors[index].parentID) {
                layout.connectors[index] = layout.connectors[index].offsetBy(dx: dx, dy: dy)
            } else {
                // Edge from the node: its start stays on the node.
                layout.connectors[index].end.x += dx
                layout.connectors[index].end.y += dy
            }
        }
        for (piece, rect) in layout.boundaryRects where block.ids.contains(piece.memberID) {
            layout.boundaryRects[piece] = rect.offsetBy(dx: dx, dy: dy)
        }
        for index in layout.obstacles.indices where block.ids.contains(layout.obstacles[index].id) {
            layout.obstacles[index] = layout.obstacles[index].offsetBy(dx: dx, dy: dy)
        }
    }
}
