import Foundation

/// A primitive, invertible mutation of one tree (main tree or a floating
/// topic's tree). Applying an edit returns its inverse.
enum TreeEdit: Equatable {
    /// Insert `node` (with its subtree) under `parentID` at `index` (clamped).
    case insert(Node, parentID: UUID, index: Int)
    /// Remove a node and its subtree. The tree's root cannot be removed.
    case remove(id: UUID)
    /// Move a node to `parentID` at `index` (index is in the target list
    /// after the node was taken out; clamped). Same tree only.
    case move(id: UUID, parentID: UUID, index: Int)
    /// Set one property of a node.
    case set(id: UUID, NodeAttribute)

    static func rename(id: UUID, text: String) -> TreeEdit { .set(id: id, .text(text)) }
    static func setCollapsed(id: UUID, _ value: Bool) -> TreeEdit { .set(id: id, .collapsed(value)) }
    static func setColor(id: UUID, _ tag: ColorTag) -> TreeEdit { .set(id: id, .colorTag(tag)) }
    static func setLayoutStyle(id: UUID, _ style: LayoutStyle?) -> TreeEdit { .set(id: id, .layoutStyle(style)) }

    /// The node id this edit is addressed to (insert: the parent).
    var targetID: UUID {
        switch self {
        case let .insert(_, parentID, _): return parentID
        case let .remove(id), let .move(id, _, _), let .set(id, _): return id
        }
    }
}

enum TreeEditError: Error, Equatable {
    case nodeNotFound
    case cannotRemoveRoot
    case cannotMoveRoot
    case cannotAddSiblingToRoot
    /// Target parent is the node itself or one of its descendants.
    case invalidMoveTarget
    case duplicateID
    case invalidRelationship
    case invalidBoundary
}

extension Node {
    /// Applies `edit` to this tree (self is the root) and returns the inverse.
    /// On error the tree is left unchanged.
    @discardableResult
    mutating func apply(_ edit: TreeEdit) throws -> TreeEdit {
        switch edit {
        case let .insert(node, parentID, index):
            return try insert(node, parentID: parentID, index: index)
        case let .remove(id):
            return try remove(id: id)
        case let .move(id, parentID, index):
            return try move(id: id, parentID: parentID, index: index)
        case let .set(id, attribute):
            guard let path = path(to: id) else { throw TreeEditError.nodeNotFound }
            let old = modify(at: path) { node -> NodeAttribute in
                defer { attribute.write(to: &node) }
                return attribute.current(in: node)
            }
            return .set(id: id, old)
        }
    }

    private mutating func insert(_ node: Node, parentID: UUID, index: Int) throws -> TreeEdit {
        guard let parentPath = path(to: parentID) else { throw TreeEditError.nodeNotFound }
        guard !contains(node.id) else { throw TreeEditError.duplicateID }
        modify(at: parentPath) { parent in
            let clamped = min(max(index, 0), parent.children.count)
            parent.children.insert(node, at: clamped)
        }
        return .remove(id: node.id)
    }

    private mutating func remove(id: UUID) throws -> TreeEdit {
        guard let path = path(to: id) else { throw TreeEditError.nodeNotFound }
        guard let index = path.last else { throw TreeEditError.cannotRemoveRoot }
        let parentPath = Array(path.dropLast())
        let parentID = node(at: parentPath).id
        let removed = modify(at: parentPath) { $0.children.remove(at: index) }
        return .insert(removed, parentID: parentID, index: index)
    }

    private mutating func move(id: UUID, parentID: UUID, index: Int) throws -> TreeEdit {
        guard let path = path(to: id) else { throw TreeEditError.nodeNotFound }
        guard let oldIndex = path.last else { throw TreeEditError.cannotMoveRoot }
        guard contains(parentID) else { throw TreeEditError.nodeNotFound }
        guard !node(at: path).contains(parentID) else { throw TreeEditError.invalidMoveTarget }

        let oldParentPath = Array(path.dropLast())
        let oldParentID = node(at: oldParentPath).id
        let moved = modify(at: oldParentPath) { $0.children.remove(at: oldIndex) }
        // Paths may have shifted after removal; look the target up again.
        guard let newParentPath = self.path(to: parentID) else { throw TreeEditError.nodeNotFound }
        modify(at: newParentPath) { parent in
            let clamped = min(max(index, 0), parent.children.count)
            parent.children.insert(moved, at: clamped)
        }
        return .move(id: id, parentID: oldParentID, index: oldIndex)
    }
}
