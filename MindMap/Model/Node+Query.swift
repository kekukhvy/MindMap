import Foundation

extension Node {
    /// Child-index path from `self` to the node with `id` (`[]` = self).
    func path(to id: UUID) -> [Int]? {
        if self.id == id { return [] }
        for (index, child) in children.enumerated() {
            if let sub = child.path(to: id) { return [index] + sub }
        }
        return nil
    }

    func node(withID id: UUID) -> Node? {
        guard let path = path(to: id) else { return nil }
        return node(at: path)
    }

    func node(at path: [Int]) -> Node {
        var current = self
        for index in path { current = current.children[index] }
        return current
    }

    /// Parent of `id`, or nil if `id` is self or not in the tree.
    func parent(of id: UUID) -> Node? {
        guard let path = path(to: id), !path.isEmpty else { return nil }
        return node(at: Array(path.dropLast()))
    }

    /// True if `id` is self or any descendant.
    func contains(_ id: UUID) -> Bool {
        path(to: id) != nil
    }

    /// Total number of nodes in this subtree, including self.
    var subtreeCount: Int {
        1 + children.reduce(0) { $0 + $1.subtreeCount }
    }

    /// Mutates the node at `path` in place.
    mutating func modify<T>(at path: [Int], _ body: (inout Node) throws -> T) rethrows -> T {
        guard let first = path.first else { return try body(&self) }
        return try children[first].modify(at: Array(path.dropFirst()), body)
    }
}
