import Foundation

/// Selection navigation for a horizontal tree (arrow keys):
/// left = parent, right = first visible child, up/down = prev/next sibling.
extension Node {
    func parentID(of id: UUID) -> UUID? {
        parent(of: id)?.id
    }

    /// First child if the node is expanded, else nil.
    func firstVisibleChildID(of id: UUID) -> UUID? {
        guard let node = node(withID: id), !node.isCollapsed else { return nil }
        return node.children.first?.id
    }

    func previousSiblingID(of id: UUID) -> UUID? {
        sibling(of: id, offset: -1)
    }

    func nextSiblingID(of id: UUID) -> UUID? {
        sibling(of: id, offset: 1)
    }

    /// Where selection should go after deleting `id`:
    /// next sibling, else previous sibling, else parent.
    func selectionAfterDeleting(_ id: UUID) -> UUID? {
        nextSiblingID(of: id) ?? previousSiblingID(of: id) ?? parentID(of: id)
    }

    /// IDs of all visible nodes (collapsed subtrees skipped), pre-order.
    var visibleIDs: [UUID] {
        var result = [id]
        if !isCollapsed {
            for child in children { result += child.visibleIDs }
        }
        return result
    }

    /// True if `id` is in the tree and none of its ancestors is collapsed.
    func isVisible(_ id: UUID) -> Bool {
        guard let path = path(to: id) else { return false }
        var current = self
        for index in path {
            if current.isCollapsed { return false }
            current = current.children[index]
        }
        return true
    }

    private func sibling(of id: UUID, offset: Int) -> UUID? {
        guard let path = path(to: id), let index = path.last else { return nil }
        let siblings = node(at: Array(path.dropLast())).children
        let target = index + offset
        return siblings.indices.contains(target) ? siblings[target].id : nil
    }
}
