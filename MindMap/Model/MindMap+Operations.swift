import CoreGraphics
import Foundation

/// Map-level operations: build `MapEdit`s (validated) that the undo-aware
/// `MindMapModel` applies as one undo step. Deleting nodes also removes
/// relationships/boundaries referring to them, so undo restores everything.
extension MindMap {
    private func treeOrThrow(containing id: UUID) throws -> Node {
        guard let tree = tree(containing: id) else { throw TreeEditError.nodeNotFound }
        return tree
    }

    func addChildEdits(_ child: Node, to parentID: UUID) throws -> [MapEdit] {
        try treeOrThrow(containing: parentID).addChildEdits(child, to: parentID).map(MapEdit.tree)
    }

    func addSiblingEdits(_ sibling: Node, after siblingID: UUID) throws -> [MapEdit] {
        [.tree(try treeOrThrow(containing: siblingID).addSiblingEdit(sibling, after: siblingID))]
    }

    func setAttributeEdits(_ attribute: NodeAttribute, for id: UUID, wholeBranch: Bool = false) throws -> [MapEdit] {
        try treeOrThrow(containing: id).setAttributeEdits(attribute, for: id, wholeBranch: wholeBranch).map(MapEdit.tree)
    }

    func toggleCollapseEdits(_ id: UUID) throws -> [MapEdit] {
        [.tree(try treeOrThrow(containing: id).toggleCollapseEdit(id))]
    }

    /// Deletes a node (or a whole floating topic) plus dependent items.
    func deleteEdits(_ id: UUID) throws -> [MapEdit] {
        guard id != root.id else { throw TreeEditError.cannotRemoveRoot }
        guard let node = node(withID: id) else { throw TreeEditError.nodeNotFound }
        var edits = cleanupEdits(removing: Set(node.allIDs))
        edits.append(isFloatingRoot(id) ? .removeFloating(id: id) : .tree(.remove(id: id)))
        return edits
    }

    /// Edits removing relationships/boundaries that refer to `ids`.
    func cleanupEdits(removing ids: Set<UUID>) -> [MapEdit] {
        var edits: [MapEdit] = relationships
            .filter { ids.contains($0.fromNodeID) || ids.contains($0.toNodeID) }
            .map { .removeRelationship(id: $0.id) }
        for boundary in boundaries {
            if ids.contains(boundary.nodeID) {
                edits.append(.removeBoundary(id: boundary.id))
            } else if boundary.siblingIDs.contains(where: ids.contains) {
                var updated = boundary
                updated.siblingIDs.removeAll(where: ids.contains)
                edits.append(.updateBoundary(updated))
            }
        }
        return edits
    }

    /// Moves `id` under `newParentID`, also across trees (floating topic into
    /// the main tree, or between trees). Rejects self/descendant targets.
    func reparentEdits(_ id: UUID, to newParentID: UUID, at index: Int? = nil) throws -> [MapEdit] {
        guard id != root.id else { throw TreeEditError.cannotMoveRoot }
        guard let moving = node(withID: id), let target = node(withID: newParentID) else {
            throw TreeEditError.nodeNotFound
        }
        guard !moving.contains(newParentID) else { throw TreeEditError.invalidMoveTarget }
        let sourceTree = try treeOrThrow(containing: id)
        let leavesParent = parentID(of: id) != newParentID
        let cleanup = leavesParent ? boundaryEditsForMoving(id) : []
        if !isFloatingRoot(id), sourceTree.contains(newParentID) {
            return try sourceTree.reparentEdits(id, to: newParentID, at: index).map(MapEdit.tree) + cleanup
        }
        var edits: [MapEdit] = cleanup
        if target.isCollapsed { edits.append(.tree(.setCollapsed(id: newParentID, false))) }
        edits.append(isFloatingRoot(id) ? .removeFloating(id: id) : .tree(.remove(id: id)))
        edits.append(.tree(.insert(moving, parentID: newParentID, index: index ?? target.children.count)))
        return edits
    }

    func addFloatingEdits(_ node: Node, at position: CGPoint) -> [MapEdit] {
        [.insertFloating(FloatingTopic(node: node, position: position), index: floatingTopics.count)]
    }

    /// Detaches a tree node (with subtree) into a floating topic at `position`.
    func detachEdits(_ id: UUID, to position: CGPoint) throws -> [MapEdit] {
        guard id != root.id else { throw TreeEditError.cannotMoveRoot }
        guard !isFloatingRoot(id) else { return [.moveFloating(id: id, to: position)] }
        guard let node = node(withID: id) else { throw TreeEditError.nodeNotFound }
        return boundaryEditsForMoving(id) + [
            .tree(.remove(id: id)),
            .insertFloating(FloatingTopic(node: node, position: position), index: floatingTopics.count)
        ]
    }

    /// Sibling-range boundaries stop being valid when `id` leaves its parent:
    /// drop `id` from other boundaries' sibling lists and clear the sibling
    /// list of boundaries anchored on `id` (the subtree boundary stays).
    func boundaryEditsForMoving(_ id: UUID) -> [MapEdit] {
        boundaries.compactMap { boundary in
            var updated = boundary
            if boundary.nodeID == id {
                updated.siblingIDs = []
            } else {
                updated.siblingIDs.removeAll { $0 == id }
            }
            return updated == boundary ? nil : .updateBoundary(updated)
        }
    }

    func moveFloatingEdits(_ id: UUID, to position: CGPoint) throws -> [MapEdit] {
        guard isFloatingRoot(id) else { throw TreeEditError.nodeNotFound }
        return [.moveFloating(id: id, to: position)]
    }

    func addRelationshipEdits(_ relationship: Relationship) throws -> [MapEdit] {
        guard relationship.fromNodeID != relationship.toNodeID,
              contains(relationship.fromNodeID), contains(relationship.toNodeID) else {
            throw TreeEditError.invalidRelationship
        }
        return [.insertRelationship(relationship, index: relationships.count)]
    }

    /// Edits changing a relationship via `change` (label, style, offsets...).
    func updateRelationshipEdits(_ id: UUID, _ change: (inout Relationship) -> Void) throws -> [MapEdit] {
        guard var relationship = relationships.first(where: { $0.id == id }) else {
            throw TreeEditError.invalidRelationship
        }
        change(&relationship)
        return [.updateRelationship(relationship)]
    }

    /// Boundary around `nodeID`'s subtree, optionally plus sibling subtrees.
    func addBoundaryEdits(_ boundary: Boundary) throws -> [MapEdit] {
        guard let tree = tree(containing: boundary.nodeID) else { throw TreeEditError.invalidBoundary }
        let parent = tree.parentID(of: boundary.nodeID)
        let siblingsValid = boundary.siblingIDs.allSatisfy {
            $0 != boundary.nodeID && parent != nil && tree.parentID(of: $0) == parent
        }
        guard siblingsValid else { throw TreeEditError.invalidBoundary }
        return [.insertBoundary(boundary, index: boundaries.count)]
    }

    func updateBoundaryEdits(_ id: UUID, _ change: (inout Boundary) -> Void) throws -> [MapEdit] {
        guard var boundary = boundaries.first(where: { $0.id == id }) else { throw TreeEditError.invalidBoundary }
        change(&boundary)
        return [.updateBoundary(boundary)]
    }
}
