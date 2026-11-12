import Foundation

/// Attachment actions (one undo step each; opening is UI only).
extension EditorController {
    func attachments(of id: UUID) -> [Attachment] {
        model.map.node(withID: id)?.attachments ?? []
    }

    /// First note of the topic; a still-empty new note (draft) counts too,
    /// so Cmd+Shift+N re-opens it instead of starting another one.
    func firstNote(of id: UUID) -> Attachment? {
        (attachments(of: id) + model.drafts(of: id)).first { $0.kind == .markdown }
    }

    /// Shows the attachment: sheet on iPad, its own window on macOS.
    func openAttachment(_ attachmentID: UUID) {
        commitEditing()
        guard let attachment = model.attachment(attachmentID) else { return }
        presentedAttachment = AttachmentRequest(attachmentID: attachmentID, fullScreen: attachment.kind == .drawing)
    }

    func firstDrawing(of id: UUID) -> Attachment? {
        (attachments(of: id) + model.drafts(of: id)).first { $0.kind == .drawing }
    }

    /// Starts a new, empty handwritten note on `id` (default: selection) and
    /// opens it. It joins the map with its first stroke; closed empty, it
    /// is dropped without an undo step (`MindMapModel+Drafts`).
    func addDrawing(to id: UUID? = nil) {
        commitEditing()
        guard let target = id ?? selectedID, let drawing = model.startDrawing(on: target) else { return }
        select(target)
        openAttachment(drawing)
    }

    /// Cmd+Shift+D: opens the topic's first handwritten note, else adds one.
    func openOrAddDrawing(_ id: UUID? = nil) {
        guard let target = id ?? selectedID else { return }
        if let drawing = firstDrawing(of: target) {
            select(target)
            openAttachment(drawing.id)
        } else {
            addDrawing(to: target)
        }
    }

    /// Starts a new, empty Markdown note on `id` (default: selection) and
    /// opens it. It joins the map with its first text; closed empty, it is
    /// dropped without an undo step (`MindMapModel+Drafts`).
    func addNote(to id: UUID? = nil) {
        commitEditing()
        guard let target = id ?? selectedID, let note = model.startNote(on: target) else { return }
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

    /// Hides icons of empty notes / drawings (`MapScene.build`).
    func hidesAttachmentIcon(_ attachment: Attachment) -> Bool {
        attachment.kind != .file && model.isContentEmpty(attachment)
    }

    /// Moves the attachment `offset` places within its topic's icon row.
    func moveAttachment(_ attachmentID: UUID, by offset: Int) {
        guard let found = model.map.attachment(withID: attachmentID),
              let index = attachments(of: found.nodeID).firstIndex(where: { $0.id == attachmentID }) else { return }
        model.moveAttachment(attachmentID, to: index + offset, undoManager: undoManager)
    }
}
