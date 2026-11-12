import Foundation

/// Identifies the attachment content step that typing may still extend.
struct ContentStepKey: Equatable {
    var fileName: String
    var manager: ObjectIdentifier
    var time: Date
}

/// Undoable attachment operations (one undo step each). File content lives
/// in `attachmentStore`; removing an attachment keeps its bytes there, so
/// undo (also of deleting the topic) brings the file back.
extension MindMapModel {
    /// Typing pauses longer than this start a new "Edit Note" undo step.
    static let contentCoalesceInterval: TimeInterval = 2

    func attachment(_ id: UUID) -> Attachment? {
        map.attachment(withID: id)?.attachment
    }

    func content(of attachmentID: UUID) -> Data? {
        attachment(attachmentID).flatMap { attachmentStore.data(for: $0.fileName) }
    }

    /// Adds `attachment` to `nodeID` (appended unless `index`), storing
    /// `content` as its file first.
    @discardableResult
    func addAttachment(_ attachment: Attachment, to nodeID: UUID, content: Data? = nil, at index: Int? = nil,
                       actionName: String = "Add Attachment", undoManager: UndoManager?) -> Bool {
        guard Attachment.isValidFileName(attachment.fileName),
              let edits = try? map.addAttachmentEdits(attachment, to: nodeID, at: index), !edits.isEmpty else {
            return false
        }
        if let content { attachmentStore.write(content, to: attachment.fileName) }
        return perform(edits, actionName: actionName, undoManager: undoManager)
    }

    /// New Markdown note on `nodeID`, starting with "# <topic text>".
    @discardableResult
    func addNote(to nodeID: UUID, undoManager: UndoManager?) -> UUID? {
        guard let node = map.node(withID: nodeID) else { return nil }
        let count = node.attachments.filter { $0.kind == .markdown }.count
        let attachment = Attachment(kind: .markdown, title: count == 0 ? "Note" : "Note \(count + 1)")
        let content = MarkdownNote.data(MarkdownNote.initialContent(topicText: node.text))
        return addAttachment(attachment, to: nodeID, content: content, actionName: "Add Note",
                             undoManager: undoManager) ? attachment.id : nil
    }

    /// New, empty handwritten note (PencilKit drawing) on `nodeID`.
    @discardableResult
    func addDrawing(to nodeID: UUID, content: Data? = nil, undoManager: UndoManager?) -> UUID? {
        guard let node = map.node(withID: nodeID) else { return nil }
        let count = node.attachments.filter { $0.kind == .drawing }.count
        let attachment = Attachment(kind: .drawing, title: HandwrittenNote.defaultTitle(index: count))
        return addAttachment(attachment, to: nodeID, content: content ?? HandwrittenNote.emptyData,
                             actionName: "Add Handwritten Note", undoManager: undoManager) ? attachment.id : nil
    }

    @discardableResult
    func removeAttachment(_ id: UUID, undoManager: UndoManager?) -> Bool {
        let name: String
        switch attachment(id)?.kind {
        case .markdown: name = "Remove Note"
        case .drawing: name = "Remove Handwritten Note"
        case .file: name = "Remove File"
        case nil: name = "Remove Attachment"
        }
        guard let edits = try? map.removeAttachmentEdits(id), !edits.isEmpty else { return false }
        return perform(edits, actionName: name, undoManager: undoManager)
    }

    @discardableResult
    func renameAttachment(_ id: UUID, to title: String, undoManager: UndoManager?) -> Bool {
        guard let current = attachment(id), current.title != title,
              let edits = try? map.updateAttachmentEdits(id, { $0.title = title }), !edits.isEmpty else { return false }
        return perform(edits, actionName: "Rename Attachment", undoManager: undoManager)
    }

    /// Reorders within the topic's attachment list (icons order).
    @discardableResult
    func moveAttachment(_ id: UUID, to index: Int, undoManager: UndoManager?) -> Bool {
        guard let edits = try? map.moveAttachmentEdits(id, to: index), !edits.isEmpty else { return false }
        return perform(edits, actionName: "Move Attachment", undoManager: undoManager)
    }

    /// New content for an attachment's file. Registers an undo step (which
    /// marks the document dirty) and bumps `modifiedAt`; further edits within
    /// `contentCoalesceInterval` of each other join that step unless
    /// `coalescing` is false (drawings: the editor batches strokes itself).
    @discardableResult
    func setAttachmentContent(_ data: Data, for attachmentID: UUID, actionName: String = "Edit Note",
                              coalescing: Bool = true, undoManager: UndoManager?, now: Date = Date()) -> Bool {
        guard let attachment = attachment(attachmentID), Attachment.isValidFileName(attachment.fileName),
              attachmentStore.data(for: attachment.fileName) != data else { return false }
        let fileName = attachment.fileName
        if coalescing, let undoManager, let last = lastContentStep, last.fileName == fileName,
           last.manager == ObjectIdentifier(undoManager), !undoManager.isUndoing, !undoManager.isRedoing,
           !undoManager.canRedo, undoManager.undoActionName == actionName,
           now.timeIntervalSince(last.time) < Self.contentCoalesceInterval {
            attachmentStore.write(data, to: fileName)
            lastContentStep?.time = now
            return true
        }
        let touch = (try? map.updateAttachmentEdits(attachmentID, { $0.modifiedAt = now })) ?? []
        return applyContentStep(fileName: fileName, data: data, mapEdits: touch, actionName: actionName,
                                undoManager: undoManager, now: now)
    }

    /// Writes `data` + applies `mapEdits` as one undo step whose inverse
    /// restores the previous bytes and map state.
    private func applyContentStep(fileName: String, data: Data, mapEdits: [MapEdit], actionName: String,
                                  undoManager: UndoManager?, now: Date) -> Bool {
        var newMap = map
        guard let inverses = try? newMap.apply(mapEdits) else { return false }
        let old = attachmentStore.data(for: fileName) ?? Data()
        if !mapEdits.isEmpty { replaceMapKeepingUndo(newMap) }
        attachmentStore.write(data, to: fileName)
        endMapCoalescing()
        guard let undoManager else {
            lastContentStep = nil
            return true
        }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            _ = model.applyContentStep(fileName: fileName, data: old, mapEdits: inverses, actionName: actionName,
                                       undoManager: undoManager, now: Date())
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        let isReplay = undoManager.isUndoing || undoManager.isRedoing
        lastContentStep = isReplay ? nil
            : ContentStepKey(fileName: fileName, manager: ObjectIdentifier(undoManager), time: now)
        return true
    }
}
