import Foundation

/// Attachment actions (one undo step each; opening is UI only).
extension EditorController {
    func attachments(of id: UUID) -> [Attachment] {
        model.map.node(withID: id)?.attachments ?? []
    }

    func firstNote(of id: UUID) -> Attachment? {
        attachments(of: id).first { $0.kind == .markdown }
    }

    /// Shows the attachment: sheet on iPad, its own window on macOS.
    func openAttachment(_ attachmentID: UUID) {
        commitEditing()
        guard model.attachment(attachmentID) != nil else { return }
        presentedAttachment = AttachmentRequest(attachmentID: attachmentID)
    }

    /// Adds a new Markdown note to `id` (default: selection) and opens it.
    func addNote(to id: UUID? = nil) {
        commitEditing()
        guard let target = id ?? selectedID, model.map.node(withID: target) != nil,
              let note = model.addNote(to: target, undoManager: undoManager) else { return }
        select(target)
        openAttachment(note)
    }

    /// Toolbar "Note" / Cmd+Shift+N: opens the topic's first note, else adds one.
    func openOrAddNote(_ id: UUID? = nil) {
        guard let target = id ?? selectedID else { return }
        if let note = firstNote(of: target) {
            select(target)
            openAttachment(note.id)
        } else {
            addNote(to: target)
        }
    }

    func removeAttachment(_ attachmentID: UUID) {
        commitEditing()
        model.removeAttachment(attachmentID, undoManager: undoManager)
    }

    /// Moves the attachment `offset` places within its topic's icon row.
    func moveAttachment(_ attachmentID: UUID, by offset: Int) {
        guard let found = model.map.attachment(withID: attachmentID),
              let index = attachments(of: found.nodeID).firstIndex(where: { $0.id == attachmentID }) else { return }
        model.moveAttachment(attachmentID, to: index + offset, undoManager: undoManager)
    }
}
