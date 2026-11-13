import SwiftUI

/// Favorites: "Mark as Favorite" and the floating Favorites panel (a copy
/// of the Tasks panel's behaviour: derived rows, draggable, collapsible).
extension EditorController {
    /// Whether every topic a menu action on `id` (default: the selection)
    /// applies to is a favorite: the item then reads "Remove from Favorites".
    func targetsAreFavorites(for id: UUID? = nil) -> Bool {
        let ids = targets(for: id)
        return !ids.isEmpty && ids.allSatisfy { model.map.node(withID: $0)?.isFavorite == true }
    }

    /// Menu item: marks the topic (or every topic of the multi-selection it
    /// belongs to) as favorite, or removes the mark when all are favorites.
    func toggleFavorite(_ id: UUID? = nil) {
        guard requireEditable() else { return }
        commitEditing()
        model.toggleFavorite(targets(for: id), undoManager: undoManager)
    }

    /// Remove from Favorites (panel row menu).
    func removeFavorite(_ id: UUID) {
        guard requireEditable() else { return }
        model.setFavorite([id], false, undoManager: undoManager)
    }

    // MARK: Favorites panel

    /// The panel as drawn now (nil = hidden: no favorite).
    var favoritesPanel: FavoritesPanelContent? {
        FavoritesPanelLayout.content(map: model.map, contentBounds: scene.layout.bounds, tasksFrame: taskPanel?.frame)
    }

    /// Screen rect of the panel's scrolling row list (macOS scroll wheel).
    var favoritesListScrollRect: CGRect? {
        guard let panel = favoritesPanel, panel.scrollsRows, !panel.isCollapsed else { return nil }
        let screen = viewport.toScreen(panel.frame)
        return TaskPanelLayout.listFrame(in: screen, rows: TaskPanelLayout.maxRows, scale: viewport.scale)
    }

    /// Frame of the Favorites panel when the user dragged it somewhere.
    var fixedFavoritesPanelFrame: CGRect? {
        FavoritesPanelLayout.fixedFrame(map: model.map)
    }

    /// Row click: select the topic and scroll it into view (same as the Tasks panel).
    func showFavorite(_ id: UUID) {
        showTask(id)
    }

    func toggleFavoritesPanelCollapsed() {
        commitEditing()
        let collapsed = model.map.favoritesPanel?.isCollapsed ?? false
        withAnimation(.snappy(duration: 0.2)) {
            _ = model.setFavoritesPanelCollapsed(!collapsed, undoManager: undoManager)
        }
    }

    func updateFavoritesPanelDrag(_ translation: CGSize) {
        // Read-only map: the drag pans the canvas, like the Tasks panel.
        guard canEdit else {
            updateTaskPanelDrag(translation)
            return
        }
        favoritesPanelDrag = translation
    }

    func endFavoritesPanelDrag() {
        endTaskPanelDrag()
        guard let translation = favoritesPanelDrag else { return }
        favoritesPanelDrag = nil
        guard translation != .zero, let frame = favoritesPanel?.frame else { return }
        let origin = CGPoint(x: (frame.minX + translation.width / viewport.scale).rounded(),
                             y: (frame.minY + translation.height / viewport.scale).rounded())
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { _ = model.moveFavoritesPanel(to: origin, undoManager: undoManager) }
    }

    func resetFavoritesPanelPosition() {
        model.moveFavoritesPanel(to: nil, undoManager: undoManager)
    }
}
