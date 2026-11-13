import Foundation

// "Lock Editing" (WP15): a read-only map. `MindMap.isReadOnly` is saved in
// map.json (and synced with the library like any other field). While it is
// on, the model's ONE mutation entry (`perform`, plus the attachment-byte
// and draft paths that do not go through `perform`) refuses every
// UI-initiated change except the few listed in `isAllowedWhileReadOnly`
// — so a new feature that edits the map through the model cannot bypass
// the lock. The editor disables its menus and reports refusals as a short
// notice ("Map is locked — unlock to edit").
//
// Decisions:
// - Toggling the lock IS an undo step ("Lock Editing" / "Unlock Editing").
//   It is saved document data; the document's dirty state comes from undo
//   registrations (same reasoning as WP7 reveal / WP8 panel), so the change
//   persists and syncs without a special save path. It also keeps undo
//   safe: registering the lock clears the redo stack, and while locked only
//   collapse / expand steps can be added on top of it, so ⌘Z while locked
//   only ever undoes a fold or the lock itself (which unlocks) — it can never
//   change content behind the lock. Undo / redo replays are therefore not
//   gated (refusing a replay would drop the step from the history).
// - Expand / collapse stay allowed (reading a map means folding it), as do
//   "Show Topic" (Go to / Tasks panel reveal), collapsing the Tasks panel
//   (not moving it) and the map title (named like its file / package).
extension MapEdit {
    /// Whether this edit may run on a read-only map (`map` = before it).
    func isAllowedWhileReadOnly(in map: MindMap) -> Bool {
        switch self {
        case .setReadOnly, .setTitle:
            return true
        case .tree(.set(_, .collapsed(_))):
            return true
        case let .setTaskPanel(state):
            // Folding the panel is fine, dragging it somewhere is an edit.
            return state?.position == map.taskPanel?.position
        default:
            return false
        }
    }

    /// Topics folded / unfolded by `edits` when that is all they do (side
    /// pins of the same step aside); empty otherwise.
    static func collapseTargets(of edits: [MapEdit]) -> [UUID] {
        var ids: [UUID] = []
        for edit in edits {
            switch edit {
            case let .tree(.set(id, .collapsed(_))): ids.append(id)
            case .tree(.set(_, .side(_))): continue
            default: return []
            }
        }
        return ids
    }
}

extension MindMapModel {
    var isReadOnly: Bool { map.isReadOnly }

    /// "Lock Editing" / "Unlock Editing": one undo step (see above).
    @discardableResult
    func setReadOnly(_ readOnly: Bool, undoManager: UndoManager?) -> Bool {
        guard readOnly != map.isReadOnly else { return false }
        return perform([.setReadOnly(readOnly)], actionName: readOnly ? "Lock Editing" : "Unlock Editing",
                       undoManager: undoManager)
    }

    /// Whether `edits` may be applied now (always unless read-only).
    func permits(_ edits: [MapEdit]) -> Bool {
        guard map.isReadOnly, readOnlyBypassDepth == 0 else { return true }
        let map = map
        return edits.allSatisfy { $0.isAllowedWhileReadOnly(in: map) }
    }

    /// The gate of every mutation: undo / redo replays pass, refused edits
    /// are reported to the editor (notice) and change nothing.
    func admits(_ edits: [MapEdit], actionName: String, undoManager: UndoManager?) -> Bool {
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return true }
        guard !permits(edits) else { return true }
        readOnlyRejectionHandler?(actionName)
        return false
    }

    /// Gate for changes that are not map edits (attachment bytes, new
    /// drafts, note lock files): refused on a read-only map.
    func admitsContentChange(_ actionName: String, undoManager: UndoManager?) -> Bool {
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return true }
        guard map.isReadOnly, readOnlyBypassDepth == 0 else { return true }
        readOnlyRejectionHandler?(actionName)
        return false
    }

    /// Runs bookkeeping that is not a user edit (refreshed map-link paths)
    /// past the read-only gate.
    func bypassingReadOnly<T>(_ body: () -> T) -> T {
        readOnlyBypassDepth += 1
        defer { readOnlyBypassDepth -= 1 }
        return body()
    }
}
