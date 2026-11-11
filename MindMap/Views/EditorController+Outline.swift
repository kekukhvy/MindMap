import Foundation

/// Free positions and outline (collapse/expand) actions. Each is one undo
/// step; the selection moves to the nearest visible ancestor if hidden.
extension EditorController {
    func collapseToLevel(_ level: Int) {
        commitEditing()
        model.collapseToLevel(level, undoManager: undoManager)
        validateSelection()
    }

    /// Expands the whole map.
    func expandAll() {
        commitEditing()
        model.expandAll(undoManager: undoManager)
        validateSelection()
    }

    func expandBranch(_ id: UUID? = nil) {
        guard let id = id ?? selectedID else { return }
        commitEditing()
        model.expandAll(in: id, undoManager: undoManager)
    }

    func collapseBranch(_ id: UUID? = nil) {
        guard let id = id ?? selectedID else { return }
        commitEditing()
        model.collapseBranch(id, undoManager: undoManager)
        validateSelection()
    }

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
