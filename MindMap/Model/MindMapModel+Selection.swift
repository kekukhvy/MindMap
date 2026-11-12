import CoreGraphics
import Foundation

extension MindMap {
    /// Edits of `build` for every id in turn, each built against the map as
    /// changed by the previous ones (so cleanups never repeat and indices
    /// stay right). Ids whose edits are invalid are skipped. Applying the
    /// result to `self` gives the same map as applying them one by one.
    func composedEdits(for ids: [UUID], _ build: (MindMap, UUID) throws -> [MapEdit]) -> [MapEdit] {
        var scratch = self
        var all: [MapEdit] = []
        for id in ids {
            guard let edits = try? build(scratch, id), !edits.isEmpty, (try? scratch.apply(edits)) != nil else {
                continue
            }
            all += edits
        }
        return all
    }

    /// Topics a multi-topic move / delete acts on: no central topic, no
    /// topic whose ancestor is in `ids` too (it goes with the ancestor),
    /// document order.
    func movableTopics(_ ids: some Sequence<UUID>) -> [UUID] {
        normalizedTopics(ids.filter { $0 != root.id })
    }

    /// Edits inserting `ids` (in order) next to `target` under its parent:
    /// directly before it, or directly after it.
    func insertEdits(_ ids: [UUID], beside target: UUID, after: Bool) -> [MapEdit] {
        var anchor = target
        var scratch = self
        var all: [MapEdit] = []
        for id in ids where id != target {
            guard let parent = scratch.parentID(of: anchor),
                  let siblings = scratch.node(withID: parent)?.children.map(\.id) else { break }
            // Final index after `id` left its old place.
            let remaining = siblings.filter { $0 != id }
            guard let anchorIndex = remaining.firstIndex(of: anchor) else { break }
            let index = after ? anchorIndex + 1 : anchorIndex
            if siblings.firstIndex(of: id) == index, scratch.parentID(of: id) == parent {
                // Already there.
            } else if let edits = try? scratch.reparentEdits(id, to: parent, at: index),
                      (try? scratch.apply(edits)) != nil {
                all += edits
            } else {
                continue
            }
            // After: the next one goes after this one (order kept).
            if after { anchor = id }
        }
        return all
    }
}

/// Undoable operations on several topics at once: each is ONE undo step
/// (false = nothing valid to do, nothing registered).
extension MindMapModel {
    /// Deletes topics with their subtrees (a topic whose ancestor is in
    /// `ids` is deleted with it), plus their relationships / boundary
    /// memberships.
    @discardableResult
    func delete(_ ids: [UUID], undoManager: UndoManager?) -> Bool {
        let targets = map.movableTopics(ids)
        guard targets.count != 1 else { return delete(targets[0], undoManager: undoManager) }
        let edits = map.composedEdits(for: targets) { try $0.deleteEdits($1) }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: "Delete Topics", undoManager: undoManager)
    }

    /// Moves topics under `parentID` (appended, keeping their order).
    @discardableResult
    func reparent(_ ids: [UUID], to parentID: UUID, undoManager: UndoManager?) -> Bool {
        let targets = map.movableTopics(ids).filter { map.parentID(of: $0) != parentID }
        let edits = map.composedEdits(for: targets) { try $0.reparentEdits($1, to: parentID) }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: targets.count == 1 ? "Move Topic" : "Move Topics", undoManager: undoManager)
    }

    /// Moves topics next to `target` (before / after it, keeping their order).
    @discardableResult
    func insert(_ ids: [UUID], beside target: UUID, after: Bool, undoManager: UndoManager?) -> Bool {
        let targets = map.movableTopics(ids).filter { $0 != target }
        guard !targets.contains(where: { map.node(withID: $0)?.contains(target) == true }) else { return false }
        let edits = map.insertEdits(targets, beside: target, after: after)
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: targets.count == 1 ? "Move Topic" : "Move Topics", undoManager: undoManager)
    }

    /// New free positions: floating roots get `position` (center, map
    /// coordinates), tree topics a manual offset from their parent's center.
    @discardableResult
    func moveTopics(_ moves: [(id: UUID, position: CGPoint)], undoManager: UndoManager?) -> Bool {
        var positions: [UUID: CGPoint] = [:]
        for move in moves { positions[move.id] = move.position }
        let edits = map.composedEdits(for: moves.map(\.id)) { map, id in
            let position = positions[id]!
            return map.isFloatingRoot(id) ? try map.moveFloatingEdits(id, to: position)
                : try map.setManualPositionEdits(id, to: position)
        }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: moves.count == 1 ? "Move Topic" : "Move Topics", undoManager: undoManager)
    }

    /// Sets an attribute on several topics (each optionally with its branch).
    @discardableResult
    func setAttribute(_ attribute: NodeAttribute, for ids: [UUID], wholeBranch: Bool = false,
                      actionName: String, undoManager: UndoManager?) -> Bool {
        setAttributes([attribute], for: ids, wholeBranch: wholeBranch, actionName: actionName,
                      undoManager: undoManager)
    }

    /// Several attributes on several topics, one undo step.
    @discardableResult
    func setAttributes(_ attributes: [NodeAttribute], for ids: [UUID], wholeBranch: Bool = false,
                       actionName: String, undoManager: UndoManager?) -> Bool {
        let edits = map.composedEdits(for: map.documentOrder(ids)) { map, id in
            try attributes.flatMap { try map.setAttributeEdits($0, for: id, wholeBranch: wholeBranch) }
        }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: actionName, undoManager: undoManager)
    }

    /// Collapses (or expands) every topic of `ids` that has children.
    @discardableResult
    func setCollapsed(_ collapsed: Bool, for ids: [UUID], undoManager: UndoManager?) -> Bool {
        let edits = map.composedEdits(for: map.documentOrder(ids)) { map, id in
            guard let node = map.node(withID: id), !node.children.isEmpty, node.isCollapsed != collapsed else {
                return []
            }
            return [.tree(.setCollapsed(id: id, collapsed))]
        }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: collapsed ? "Collapse" : "Expand", undoManager: undoManager)
    }

    /// "Convert to Task" for every plain topic of `ids`.
    @discardableResult
    func makeTasks(_ ids: [UUID], undoManager: UndoManager?) -> Bool {
        let edits = map.composedEdits(for: map.documentOrder(ids)) { map, id in
            map.node(withID: id)?.task == nil ? try map.setTaskEdits(TaskInfo(), for: id) : []
        }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: "Convert to Task", undoManager: undoManager)
    }

    /// "Convert to Topic" for every task of `ids`.
    @discardableResult
    func removeTasks(_ ids: [UUID], undoManager: UndoManager?) -> Bool {
        let edits = map.composedEdits(for: map.documentOrder(ids)) { map, id in
            map.node(withID: id)?.task != nil ? try map.setTaskEdits(nil, for: id) : []
        }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: "Convert to Topic", undoManager: undoManager)
    }

    /// Marks every task of `ids` done (stamping `completedAt`) or open.
    @discardableResult
    func setTasksDone(_ ids: [UUID], _ done: Bool, now: Date = Date(), undoManager: UndoManager?) -> Bool {
        let edits = map.composedEdits(for: map.documentOrder(ids)) { map, id in
            guard var task = map.node(withID: id)?.task, task.isDone != done else { return [] }
            task.isDone = done
            task.completedAt = done ? now : nil
            return try map.setTaskEdits(task, for: id)
        }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: done ? "Complete Tasks" : "Reopen Tasks", undoManager: undoManager)
    }

    // MARK: Boundaries over arbitrary topics

    /// Boundary around `members` (any topics but the central one); returns its id.
    @discardableResult
    func addBoundary(members: [UUID], label: String? = nil, undoManager: UndoManager?) -> UUID? {
        let boundary = Boundary(memberIDs: members, label: label)
        guard let edits = try? map.addBoundaryEdits(boundary) else { return nil }
        return perform(edits, actionName: "Add Boundary", undoManager: undoManager) ? boundary.id : nil
    }

    /// Replaces the members ("Edit Members"); none left = the boundary is removed.
    @discardableResult
    func setBoundaryMembers(_ id: UUID, to members: [UUID], undoManager: UndoManager?) -> Bool {
        guard let edits = try? map.setBoundaryMembersEdits(id, members: members), !edits.isEmpty else { return false }
        let removes = edits.contains { if case .removeBoundary = $0 { return true } else { return false } }
        return perform(edits, actionName: removes ? "Delete Boundary" : "Edit Boundary Members",
                       undoManager: undoManager)
    }
}
