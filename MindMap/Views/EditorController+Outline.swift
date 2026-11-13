import Foundation

/// Free positions and outline (collapse/expand) actions. Each is one undo
/// step; the selection moves to the nearest visible ancestor if hidden.
extension EditorController {
    func collapseToLevel(_ level: Int) {
        commitEditing()
        keepingOnScreen(selectedID) { _ = model.collapseToLevel(level, undoManager: undoManager) }
        validateSelection()
    }

    /// Expands the whole map.
    func expandAll() {
        commitEditing()
        keepingOnScreen(selectedID) { _ = model.expandAll(undoManager: undoManager) }
        validateSelection()
    }

    func expandBranch(_ id: UUID? = nil) {
        guard let id = id ?? selectedID else { return }
        commitEditing()
        keepingOnScreen(id) { _ = model.expandAll(in: id, undoManager: undoManager) }
    }

    /// Sorts the direct children of `id` (default: selection) by text.
    func sortChildren(_ id: UUID? = nil, ascending: Bool) {
        guard let id = id ?? selectedID, requireEditable() else { return }
        commitEditing()
        keepingOnScreen(id) { _ = model.sortChildren(id, ascending: ascending, undoManager: undoManager) }
    }

    func collapseBranch(_ id: UUID? = nil) {
        guard let id = id ?? selectedID else { return }
        commitEditing()
        keepingOnScreen(id) { _ = model.collapseBranch(id, undoManager: undoManager) }
        validateSelection()
    }

    /// "Rebalance Map" (WP17): splits the central topic's branches left /
    /// right again by their current height, as a new map would be (one
    /// undo step). Otherwise branches keep their side.
    func rebalanceMap() {
        commitEditing()
        let edits = model.map.rebalanceEdits(split: scene.layout.balanced)
        guard !edits.isEmpty else { return }
        keepingOnScreen(model.root.id) {
            _ = model.perform(edits, actionName: "Rebalance Map", undoManager: undoManager)
        }
    }

    /// Whether the map has a balanced (left / right) topic to rebalance.
    var canRebalance: Bool { !model.map.balancedParents().isEmpty }

    /// Returns `id`'s branch (nil = whole map) to automatic placement.
    func resetPositions(in id: UUID? = nil) {
        commitEditing()
        model.resetPositions(in: id, undoManager: undoManager)
    }

    func hasManualPosition(_ id: UUID? = nil) -> Bool {
        model.map.hasManualPosition(id)
    }

    /// Whether `id` (a non-root topic) itself was moved freely.
    func isFreelyPositioned(_ id: UUID) -> Bool {
        model.map.node(withID: id)?.manualPosition != nil && model.map.parentID(of: id) != nil
    }
}
