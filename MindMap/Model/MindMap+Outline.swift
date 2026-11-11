import CoreGraphics
import Foundation

/// Free positioning and outline (collapse / expand by level) operations.
/// Each returns the edits for ONE undo step; empty = nothing to change.
extension MindMap {
    /// All tree roots: the main root and every floating topic.
    var treeRoots: [Node] { [root] + floatingTopics.map(\.node) }

    /// Sets the free position of a non-root tree node.
    func setManualPositionEdits(_ id: UUID, to position: CGPoint?) throws -> [MapEdit] {
        guard let node = node(withID: id) else { throw TreeEditError.nodeNotFound }
        guard parentID(of: id) != nil else { throw TreeEditError.cannotMoveRoot }
        guard node.manualPosition != position else { return [] }
        return try setAttributeEdits(.manualPosition(position), for: id)
    }

    /// Clears free positions of `id` and its descendants (nil = whole map).
    func resetPositionEdits(in id: UUID? = nil) -> [MapEdit] {
        let scope = id.flatMap { node(withID: $0) }.map { [$0] } ?? (id == nil ? treeRoots : [])
        return scope.flatMap(\.allNodes)
            .filter { $0.manualPosition != nil }
            .map { .tree(.set(id: $0.id, .manualPosition(nil))) }
    }

    /// Whether `id`'s branch (nil = whole map) has a free position.
    func hasManualPosition(_ id: UUID? = nil) -> Bool {
        let scope = id.flatMap { node(withID: $0) }.map { [$0] } ?? (id == nil ? treeRoots : [])
        return scope.flatMap(\.allNodes).contains { $0.manualPosition != nil }
    }

    /// Shows every tree (main and floating) down to `level` (root = 0):
    /// topics at depth < level are expanded, deeper ones with children collapsed.
    func collapseToLevelEdits(_ level: Int) -> [MapEdit] {
        treeRoots.flatMap { tree in
            tree.nodesWithDepth().compactMap { node, depth -> MapEdit? in
                guard !node.children.isEmpty else { return nil }
                let collapsed = depth >= level
                return node.isCollapsed == collapsed ? nil : .tree(.setCollapsed(id: node.id, collapsed))
            }
        }
    }

    /// Expands every topic of `id`'s branch (nil = whole map).
    func expandAllEdits(in id: UUID? = nil) -> [MapEdit] {
        let scope = id.flatMap { node(withID: $0) }.map { [$0] } ?? (id == nil ? treeRoots : [])
        return scope.flatMap(\.allNodes)
            .filter(\.isCollapsed)
            .map { .tree(.setCollapsed(id: $0.id, false)) }
    }

    /// Collapses `id` and all its descendants that have children.
    func collapseBranchEdits(_ id: UUID) -> [MapEdit] {
        guard let node = node(withID: id) else { return [] }
        return node.allNodes
            .filter { !$0.children.isEmpty && !$0.isCollapsed }
            .map { .tree(.setCollapsed(id: $0.id, true)) }
    }
}

extension Node {
    /// All nodes of this subtree (pre-order, collapsed included).
    var allNodes: [Node] { [self] + children.flatMap(\.allNodes) }

    /// Pre-order nodes with their depth below self (self = 0).
    func nodesWithDepth(_ depth: Int = 0) -> [(Node, Int)] {
        [(self, depth)] + children.flatMap { $0.nodesWithDepth(depth + 1) }
    }
}
