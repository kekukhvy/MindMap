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
        // Members go with their topics; a boundary without members goes too.
        for boundary in boundaries where boundary.memberIDs.contains(where: ids.contains) {
            var updated = boundary
            updated.memberIDs.removeAll(where: ids.contains)
            edits.append(updated.memberIDs.isEmpty ? .removeBoundary(id: boundary.id) : .updateBoundary(updated))
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
        // A dropped topic rejoins the automatic layout of its (new) parent.
        let resetPosition: [MapEdit] = moving.manualPosition != nil ? [.tree(.set(id: id, .manualPosition(nil)))] : []
        if !isFloatingRoot(id), sourceTree.contains(newParentID) {
            return try sourceTree.reparentEdits(id, to: newParentID, at: index).map(MapEdit.tree) + cleanup
                + resetPosition
        }
        var edits: [MapEdit] = cleanup
        if target.isCollapsed { edits.append(.tree(.setCollapsed(id: newParentID, false))) }
        edits.append(isFloatingRoot(id) ? .removeFloating(id: id) : .tree(.remove(id: id)))
        var inserted = moving
        inserted.manualPosition = nil
        edits.append(.tree(.insert(inserted, parentID: newParentID, index: index ?? target.children.count)))
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

    /// Boundary members are arbitrary topics: a moved topic stays a member
    /// wherever it goes (the outline follows it), so moving needs no edits.
    func boundaryEditsForMoving(_ id: UUID) -> [MapEdit] {
        []
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

    /// Boundary around its members' subtrees (any topics except the
    /// central one; members are normalized: an ancestor encloses its
    /// descendants, document order).
    func addBoundaryEdits(_ boundary: Boundary) throws -> [MapEdit] {
        var normalized = boundary
        normalized.memberIDs = try validBoundaryMembers(boundary.memberIDs)
        return [.insertBoundary(normalized, index: boundaries.count)]
    }

    /// Replaces a boundary's members (normalized); no members = removes it.
    func setBoundaryMembersEdits(_ id: UUID, members: [UUID]) throws -> [MapEdit] {
        guard var boundary = boundaries.first(where: { $0.id == id }) else { throw TreeEditError.invalidBoundary }
        guard !members.isEmpty else { return [.removeBoundary(id: id)] }
        let valid = try validBoundaryMembers(members)
        guard valid != boundary.memberIDs else { return [] }
        boundary.memberIDs = valid
        return [.updateBoundary(boundary)]
    }

    private func validBoundaryMembers(_ members: [UUID]) throws -> [UUID] {
        guard !members.isEmpty, !members.contains(root.id), members.allSatisfy(contains) else {
            throw TreeEditError.invalidBoundary
        }
        return normalizedTopics(members)
    }

    func updateBoundaryEdits(_ id: UUID, _ change: (inout Boundary) -> Void) throws -> [MapEdit] {
        guard var boundary = boundaries.first(where: { $0.id == id }) else { throw TreeEditError.invalidBoundary }
        change(&boundary)
        return [.updateBoundary(boundary)]
    }
}
