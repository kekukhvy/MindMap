import CoreGraphics
import Foundation

/// Copy / cut / paste of topics (one undo step each for cut and paste).
extension MindMapModel {
    /// Clipboard of `ids` with their attachment bytes (locked notes are not
    /// copied: their key is bound to the note).
    func clipboard(for ids: [UUID]) -> TopicClipboard? {
        map.clipboard(for: ids) { attachmentStore.data(for: $0.fileName) }
    }

    /// Deletes the copied topics of a cut (one "Cut Topic(s)" step).
    @discardableResult
    func cut(_ ids: [UUID], undoManager: UndoManager?) -> Bool {
        let targets = map.movableTopics(ids)
        let edits = map.composedEdits(for: targets) { try $0.deleteEdits($1) }
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: targets.count == 1 ? "Cut Topic" : "Cut Topics", undoManager: undoManager)
    }

    /// Pastes `clip` under `parentID` (nil = floating topics around
    /// `point`): fresh copies, attachment files written first. Returns the
    /// new top-level topic ids (empty when refused, e.g. a read-only map).
    @discardableResult
    func paste(_ clip: TopicClipboard, into parentID: UUID?, at point: CGPoint = .zero,
               undoManager: UndoManager?) -> [UUID] {
        let instance = clip.instantiate()
        guard !instance.topics.isEmpty,
              let edits = try? map.pasteEdits(instance, into: parentID, at: point), !edits.isEmpty else { return [] }
        let name = instance.topics.count == 1 ? "Paste Topic" : "Paste Topics"
        // Read-only map (WP15): refused before any file is written.
        guard admits(edits, actionName: name, undoManager: undoManager) else { return [] }
        for (fileName, data) in instance.files { attachmentStore.write(data, to: fileName) }
        guard perform(edits, actionName: name, undoManager: undoManager) else { return [] }
        return instance.topics.map(\.id)
    }
}
