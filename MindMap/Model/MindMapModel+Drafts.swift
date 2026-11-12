import Foundation
import PencilKit

/// A note / handwritten note the user just created and that has no content
/// yet. It lives outside the map (no topic icon, not saved, no undo step)
/// until its first real content arrives, which adds it to the map as ONE
/// "Add Note" / "Add Handwritten Note" step. Closing its editor while it is
/// still empty simply drops it: creating and abandoning a note leaves no
/// trace (no icon, no undo step, document not dirtied).
struct AttachmentDraft: Equatable {
    var nodeID: UUID
    var attachment: Attachment
    /// Step registered when the draft gets content.
    var actionName: String
}

/// Empty-note lifecycle: drafts, emptiness, and cleanup when an editor closes.
extension MindMapModel {
    /// Starts a new, empty Markdown note on `nodeID` (a draft); returns its id.
    @discardableResult
    func startNote(on nodeID: UUID) -> UUID? {
        startDraft(.markdown, on: nodeID, actionName: "Add Note")
    }

    /// Starts a new, empty handwritten note on `nodeID` (a draft); returns its id.
    @discardableResult
    func startDrawing(on nodeID: UUID) -> UUID? {
        startDraft(.drawing, on: nodeID, actionName: "Add Handwritten Note")
    }

    private func startDraft(_ kind: AttachmentKind, on nodeID: UUID, actionName: String) -> UUID? {
        guard let node = map.node(withID: nodeID) else { return nil }
        let attachment = Attachment(kind: kind, title: defaultTitle(kind, on: nodeID, in: node))
        attachmentDrafts[attachment.id] = AttachmentDraft(nodeID: nodeID, attachment: attachment,
                                                          actionName: actionName)
        return attachment.id
    }

    func isDraft(_ attachmentID: UUID) -> Bool {
        attachmentDrafts[attachmentID] != nil
    }

    /// Drafts of `nodeID` (oldest first), e.g. a note window still open.
    func drafts(of nodeID: UUID) -> [Attachment] {
        attachmentDrafts.values.filter { $0.nodeID == nodeID }.map(\.attachment).sorted { $0.createdAt < $1.createdAt }
    }

    /// Content written to a draft: blank content stays a draft (bytes kept
    /// for the editor), real content adds the attachment to the map as one
    /// undo step that typing right after joins (see `ContentStepKey`).
    func writeDraftContent(_ data: Data, draft: AttachmentDraft, undoManager: UndoManager?, now: Date) -> Bool {
        let fileName = draft.attachment.fileName
        guard !Self.isEmptyContent(data, kind: draft.attachment.kind) else {
            attachmentStore.write(data, to: fileName)
            return true
        }
        attachmentDrafts[draft.attachment.id] = nil
        var attachment = draft.attachment
        attachment.modifiedAt = now
        guard addAttachment(attachment, to: draft.nodeID, content: data, actionName: draft.actionName,
                            undoManager: undoManager) else { return false }
        if let undoManager, !undoManager.isUndoing, !undoManager.isRedoing {
            lastContentStep = ContentStepKey(fileName: fileName, manager: ObjectIdentifier(undoManager), time: now,
                                             actionName: draft.actionName, isCreation: true)
        }
        return true
    }

    /// Called when an attachment's editor (window / sheet) closes. A draft
    /// is dropped without a trace; a note or handwritten note whose content
    /// is empty / whitespace only is deleted as an undoable "Delete Note" /
    /// "Delete Handwritten Note" step. Files are never removed here.
    /// Returns true when the attachment is gone.
    @discardableResult
    func discardIfEmpty(_ attachmentID: UUID, undoManager: UndoManager?) -> Bool {
        if attachmentDrafts[attachmentID] != nil {
            attachmentDrafts[attachmentID] = nil
            return true
        }
        guard let attachment = map.attachment(withID: attachmentID)?.attachment, attachment.kind != .file,
              isContentEmpty(attachment) else { return false }
        return deleteAttachment(attachmentID, undoManager: undoManager)
    }

    /// Explicit delete (editor toolbar trash): "Delete Note" / "Delete
    /// Handwritten Note" / "Delete File"; a draft is just dropped.
    @discardableResult
    func deleteAttachment(_ attachmentID: UUID, undoManager: UndoManager?) -> Bool {
        let kind = attachment(attachmentID)?.kind
        return removeAttachment(attachmentID, actionName: Self.deleteActionName(for: kind), undoManager: undoManager)
    }

    static func deleteActionName(for kind: AttachmentKind?) -> String {
        switch kind {
        case .markdown: return "Delete Note"
        case .drawing: return "Delete Handwritten Note"
        case .file: return "Delete File"
        case nil: return "Delete Attachment"
        }
    }

    /// Whether the attachment has nothing in it (blank note text / drawing
    /// without strokes). Files are never empty. Topics show icons only for
    /// non-empty attachments.
    func isContentEmpty(_ attachment: Attachment) -> Bool {
        guard attachment.kind != .file else { return false }
        let fileName = attachment.fileName
        let data = attachmentStore.data(for: fileName)
        guard attachment.kind == .drawing else { return Self.isEmptyContent(data, kind: attachment.kind) }
        let key = "\(fileName)|\(attachmentStore.revision(of: fileName))|\(data?.count ?? -1)" as NSString
        if let cached = DrawingEmptinessCache.shared.object(forKey: key) { return cached.boolValue }
        let isEmpty = Self.isEmptyContent(data, kind: .drawing)
        DrawingEmptinessCache.shared.setObject(NSNumber(value: isEmpty), forKey: key)
        return isEmpty
    }

    static func isEmptyContent(_ data: Data?, kind: AttachmentKind) -> Bool {
        switch kind {
        case .markdown:
            return MarkdownNote.text(data).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .drawing:
            return HandwrittenNote.drawing(data).strokes.isEmpty
        case .file:
            return false
        }
    }
}

/// Decoding a drawing to check for strokes is not free: cached per
/// (file, store revision, size) for scene rebuilds.
private enum DrawingEmptinessCache {
    static let shared = NSCache<NSString, NSNumber>()
}
