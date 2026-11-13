import Foundation

/// One row of the Favorites panel.
struct FavoriteEntry: Equatable, Identifiable {
    var id: UUID
    var text: String
}

/// Favorites: the derived list and the (undoable) mark / unmark edits.
extension MindMap {
    /// Every favorite topic in map order (main tree first, then floating
    /// topics, pre-order).
    var favorites: [FavoriteEntry] {
        trees.flatMap(\.allNodes).filter(\.isFavorite)
            .map { FavoriteEntry(id: $0.id, text: LinkCandidate.displayText($0.text)) }
    }

    /// Sets `isFavorite` on `id`. Empty = no change.
    func setFavoriteEdits(_ favorite: Bool, for id: UUID) throws -> [MapEdit] {
        guard let node = node(withID: id) else { throw TreeEditError.nodeNotFound }
        guard node.isFavorite != favorite else { return [] }
        return try setAttributeEdits(.favorite(favorite), for: id)
    }
}
