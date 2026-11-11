import Foundation

/// High-level, pure operations on one tree. Each builds the needed
/// `TreeEdit`s; `MindMap` wraps them into `MapEdit`s for the whole map.
extension Node {
    /// Edits that add `child` as the last child of `parentID`
    /// (expanding the parent if it is collapsed).
    func addChildEdits(_ child: Node, to parentID: UUID) throws -> [TreeEdit] {
        guard let parent = node(withID: parentID) else { throw TreeEditError.nodeNotFound }
        var edits: [TreeEdit] = []
        if parent.isCollapsed { edits.append(.setCollapsed(id: parentID, false)) }
        edits.append(.insert(child, parentID: parentID, index: parent.children.count))
        return edits
    }

    /// Edit that inserts `sibling` directly after `siblingID`.
    func addSiblingEdit(_ sibling: Node, after siblingID: UUID) throws -> TreeEdit {
        guard let path = path(to: siblingID) else { throw TreeEditError.nodeNotFound }
        guard let index = path.last else { throw TreeEditError.cannotAddSiblingToRoot }
        let parentID = node(at: Array(path.dropLast())).id
        return .insert(sibling, parentID: parentID, index: index + 1)
    }

    /// Edit that deletes `id` with its subtree. The tree root cannot be deleted.
    func deleteEdit(_ id: UUID) throws -> TreeEdit {
        guard let path = path(to: id) else { throw TreeEditError.nodeNotFound }
        guard !path.isEmpty else { throw TreeEditError.cannotRemoveRoot }
        return .remove(id: id)
    }

    /// Edits that move `id` under `newParentID` at `index` (nil = append),
    /// expanding the target if collapsed. Rejects self/descendant targets.
    func reparentEdits(_ id: UUID, to newParentID: UUID, at index: Int? = nil) throws -> [TreeEdit] {
        guard let path = path(to: id) else { throw TreeEditError.nodeNotFound }
        guard !path.isEmpty else { throw TreeEditError.cannotMoveRoot }
        guard let target = node(withID: newParentID) else { throw TreeEditError.nodeNotFound }
        guard !node(at: path).contains(newParentID) else { throw TreeEditError.invalidMoveTarget }
        var edits: [TreeEdit] = []
        if target.isCollapsed { edits.append(.setCollapsed(id: newParentID, false)) }
        let isSameParent = parent(of: id)?.id == newParentID
        let append = target.children.count - (isSameParent ? 1 : 0)
        edits.append(.move(id: id, parentID: newParentID, index: index ?? append))
        return edits
    }

    func toggleCollapseEdit(_ id: UUID) throws -> TreeEdit {
        guard let node = node(withID: id) else { throw TreeEditError.nodeNotFound }
        return .setCollapsed(id: id, !node.isCollapsed)
    }

    /// Edits setting `attribute` on `id`, or on `id` and all its
    /// descendants if `wholeBranch` ("apply to branch").
    func setAttributeEdits(_ attribute: NodeAttribute, for id: UUID, wholeBranch: Bool = false) throws -> [TreeEdit] {
        guard let node = node(withID: id) else { throw TreeEditError.nodeNotFound }
        let ids = wholeBranch ? node.allIDs : [id]
        return ids.map { .set(id: $0, attribute) }
    }

    /// All ids in this subtree (pre-order, collapsed included).
    var allIDs: [UUID] {
        [id] + children.flatMap(\.allIDs)
    }

    /// Depth of `id` below self (self = 0).
    func depth(of id: UUID) -> Int? {
        path(to: id)?.count
    }

    // MARK: Mutating conveniences (return inverses, for tests / non-undo use)

    /// Applies all edits atomically; returns inverses in undo order.
    @discardableResult
    mutating func apply(_ edits: [TreeEdit]) throws -> [TreeEdit] {
        var copy = self
        var inverses: [TreeEdit] = []
        for edit in edits { inverses.append(try copy.apply(edit)) }
        self = copy
        return inverses.reversed()
    }

    @discardableResult
    mutating func addChild(_ child: Node = Node(), to parentID: UUID) throws -> [TreeEdit] {
        try apply(addChildEdits(child, to: parentID))
    }

    @discardableResult
    mutating func addSibling(_ sibling: Node = Node(), after siblingID: UUID) throws -> TreeEdit {
        try apply(addSiblingEdit(sibling, after: siblingID))
    }

    @discardableResult
    mutating func delete(_ id: UUID) throws -> TreeEdit {
        try apply(deleteEdit(id))
    }

    @discardableResult
    mutating func reparent(_ id: UUID, to newParentID: UUID, at index: Int? = nil) throws -> [TreeEdit] {
        try apply(reparentEdits(id, to: newParentID, at: index))
    }

    @discardableResult
    mutating func toggleCollapse(_ id: UUID) throws -> TreeEdit {
        try apply(toggleCollapseEdit(id))
    }

    @discardableResult
    mutating func rename(_ id: UUID, to text: String) throws -> TreeEdit {
        try apply(.rename(id: id, text: text))
    }

    @discardableResult
    mutating func setLayoutStyle(_ style: LayoutStyle?, for id: UUID) throws -> TreeEdit {
        try apply(.setLayoutStyle(id: id, style))
    }
}
