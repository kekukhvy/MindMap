import CoreGraphics
import Foundation

/// Undoable favorites operations (one undo step each; false = no change).
/// They work on any topic, floating topics included.
extension MindMapModel {
    /// "Mark as Favorite" / "Remove from Favorites" for every topic of `ids`.
    @discardableResult
    func setFavorite(_ ids: [UUID], _ favorite: Bool, undoManager: UndoManager?) -> Bool {
        let edits = map.composedEdits(for: map.documentOrder(ids)) { try $0.setFavoriteEdits(favorite, for: $1) }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: favorite ? "Mark as Favorite" : "Remove from Favorites",
                       undoManager: undoManager)
    }

    /// The menu item: marks all `ids` when any is not a favorite, else removes all.
    @discardableResult
    func toggleFavorite(_ ids: [UUID], undoManager: UndoManager?) -> Bool {
        setFavorite(ids, ids.contains { map.node(withID: $0)?.isFavorite == false }, undoManager: undoManager)
    }

    // MARK: Favorites panel (saved document data -> undoable)

    @discardableResult
    func moveFavoritesPanel(to position: CGPoint?, undoManager: UndoManager?) -> Bool {
        var state = map.favoritesPanel ?? TaskPanelState()
        guard state.position != position else { return false }
        state.position = position
        return perform([.setFavoritesPanel(state)],
                       actionName: position == nil ? "Reset Favorites Panel" : "Move Favorites Panel",
                       undoManager: undoManager)
    }

    @discardableResult
    func setFavoritesPanelCollapsed(_ collapsed: Bool, undoManager: UndoManager?) -> Bool {
        var state = map.favoritesPanel ?? TaskPanelState()
        guard state.isCollapsed != collapsed else { return false }
        state.isCollapsed = collapsed
        return perform([.setFavoritesPanel(state)],
                       actionName: collapsed ? "Collapse Favorites Panel" : "Expand Favorites Panel",
                       undoManager: undoManager)
    }
}
