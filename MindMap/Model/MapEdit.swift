import CoreGraphics
import Foundation

/// A primitive, invertible mutation of the whole map. `apply` returns the
/// inverse, so one undo step = applying the collected inverses in reverse.
enum MapEdit: Equatable {
    /// Tree edit, routed to the tree (main or floating) containing its target.
    case tree(TreeEdit)
    case insertFloating(FloatingTopic, index: Int)
    case removeFloating(id: UUID)
    case moveFloating(id: UUID, to: CGPoint)
    case setTheme(ColorTheme)
    case insertRelationship(Relationship, index: Int)
    case removeRelationship(id: UUID)
    /// Replaces the relationship with the same id (label, style, offsets...).
    case updateRelationship(Relationship)
    case insertBoundary(Boundary, index: Int)
    case removeBoundary(id: UUID)
    case updateBoundary(Boundary)
    /// Replaces the Tasks panel state (position / collapsed).
    case setTaskPanel(TaskPanelState?)
    case setFavoritesPanel(TaskPanelState?)
    /// Replaces the map title (library maps, WP14b).
    case setTitle(String?)
    /// "Lock Editing" on / off (WP15).
    case setReadOnly(Bool)
}

extension MindMap {
    @discardableResult
    mutating func apply(_ edit: MapEdit) throws -> MapEdit {
        switch edit {
        case let .tree(treeEdit):
            if case let .insert(node, _, _) = treeEdit, !node.allIDs.allSatisfy({ !contains($0) }) {
                throw TreeEditError.duplicateID
            }
            return .tree(try modifyTree(containing: treeEdit.targetID) { try $0.apply(treeEdit) })

        case let .insertFloating(topic, index):
            guard topic.node.allIDs.allSatisfy({ !contains($0) }) else { throw TreeEditError.duplicateID }
            floatingTopics.insert(topic, at: min(max(index, 0), floatingTopics.count))
            return .removeFloating(id: topic.id)

        case let .removeFloating(id):
            guard let index = floatingTopics.firstIndex(where: { $0.id == id }) else { throw TreeEditError.nodeNotFound }
            return .insertFloating(floatingTopics.remove(at: index), index: index)

        case let .moveFloating(id, position):
            guard let index = floatingTopics.firstIndex(where: { $0.id == id }) else { throw TreeEditError.nodeNotFound }
            let old = floatingTopics[index].position
            floatingTopics[index].position = position
            return .moveFloating(id: id, to: old)

        case let .setTheme(theme):
            let old = self.theme
            self.theme = theme
            return .setTheme(old)

        case let .insertRelationship(relationship, index):
            guard relationships.allSatisfy({ $0.id != relationship.id }) else { throw TreeEditError.duplicateID }
            relationships.insert(relationship, at: min(max(index, 0), relationships.count))
            return .removeRelationship(id: relationship.id)

        case let .removeRelationship(id):
            guard let index = relationships.firstIndex(where: { $0.id == id }) else { throw TreeEditError.invalidRelationship }
            return .insertRelationship(relationships.remove(at: index), index: index)

        case let .updateRelationship(relationship):
            guard let index = relationships.firstIndex(where: { $0.id == relationship.id }) else {
                throw TreeEditError.invalidRelationship
            }
            let old = relationships[index]
            relationships[index] = relationship
            return .updateRelationship(old)

        case let .insertBoundary(boundary, index):
            guard boundaries.allSatisfy({ $0.id != boundary.id }) else { throw TreeEditError.duplicateID }
            boundaries.insert(boundary, at: min(max(index, 0), boundaries.count))
            return .removeBoundary(id: boundary.id)

        case let .removeBoundary(id):
            guard let index = boundaries.firstIndex(where: { $0.id == id }) else { throw TreeEditError.invalidBoundary }
            return .insertBoundary(boundaries.remove(at: index), index: index)

        case let .updateBoundary(boundary):
            guard let index = boundaries.firstIndex(where: { $0.id == boundary.id }) else {
                throw TreeEditError.invalidBoundary
            }
            let old = boundaries[index]
            boundaries[index] = boundary
            return .updateBoundary(old)

        case let .setTaskPanel(state):
            let old = taskPanel
            taskPanel = state
            return .setTaskPanel(old)

        case let .setFavoritesPanel(state):
            let old = favoritesPanel
            favoritesPanel = state
            return .setFavoritesPanel(old)

        case let .setTitle(title):
            let old = self.title
            self.title = title
            return .setTitle(old)

        case let .setReadOnly(value):
            let old = isReadOnly
            isReadOnly = value
            return .setReadOnly(old)
        }
    }

    /// Applies all edits atomically; returns the inverses in undo order.
    @discardableResult
    mutating func apply(_ edits: [MapEdit]) throws -> [MapEdit] {
        var copy = self
        var inverses: [MapEdit] = []
        for edit in edits { inverses.append(try copy.apply(edit)) }
        self = copy
        return inverses.reversed()
    }

    private mutating func modifyTree<T>(containing id: UUID, _ body: (inout Node) throws -> T) throws -> T {
        if root.contains(id) { return try body(&root) }
        guard let index = floatingTopics.firstIndex(where: { $0.node.contains(id) }) else {
            throw TreeEditError.nodeNotFound
        }
        return try body(&floatingTopics[index].node)
    }
}
