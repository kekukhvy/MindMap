import Foundation

extension MindMap {
    /// All trees: main tree first, then floating topics.
    var trees: [Node] { [root] + floatingTopics.map(\.node) }

    func contains(_ id: UUID) -> Bool {
        trees.contains { $0.contains(id) }
    }

    func node(withID id: UUID) -> Node? {
        for tree in trees {
            if let node = tree.node(withID: id) { return node }
        }
        return nil
    }

    /// Root of the tree (main or floating) containing `id`.
    func tree(containing id: UUID) -> Node? {
        trees.first { $0.contains(id) }
    }

    func isFloatingRoot(_ id: UUID) -> Bool {
        floatingTopics.contains { $0.id == id }
    }

    func floatingTopic(_ id: UUID) -> FloatingTopic? {
        floatingTopics.first { $0.id == id }
    }

    /// Parent in its tree (nil for the root and floating topic roots).
    func parentID(of id: UUID) -> UUID? {
        tree(containing: id)?.parentID(of: id)
    }

    func relationships(touching id: UUID) -> [Relationship] {
        relationships.filter { $0.fromNodeID == id || $0.toNodeID == id }
    }
}
