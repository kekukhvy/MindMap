import Foundation

/// Identifies the attachment content step that typing may still extend.
struct ContentStepKey: Equatable {
    var fileName: String
    var manager: ObjectIdentifier
    var time: Date
    /// Name of the step being extended ("Edit Note", or "Add Note" when the
    /// first content created the note: typing right after joins it).
    var actionName: String
    var isCreation = false
}

/// Undoable attachment operations (one undo step each). File content lives
/// in `attachmentStore`; removing an attachment keeps its bytes there, so
/// undo (also of deleting the topic) brings the file back.
extension MindMapModel {
    /// Typing pauses longer than this start a new "Edit Note" undo step.
    static let contentCoalesceInterval: TimeInterval = 2

    /// The attachment in the map, or a draft (new, still empty note).
    func attachment(_ id: UUID) -> Attachment? {
        map.attachment(withID: id)?.attachment ?? attachmentDrafts[id]?.attachment
    }

    /// The attachment's bytes; a locked note's plaintext only while it is
    /// unlocked (nil otherwise).
    func content(of attachmentID: UUID) -> Data? {
        attachment(attachmentID).flatMap(decryptedContent(of:))
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
        // Read-only map (WP15): refused before any file is written.
        guard admits(edits, actionName: actionName, undoManager: undoManager) else { return false }
        if let content { attachmentStore.write(content, to: attachment.fileName) }
        return perform(edits, actionName: actionName, undoManager: undoManager)
    }

    /// Markdown note on `nodeID` with `text` (added now, one "Add Note"
    /// step). The editor starts notes as drafts instead (`startNote`).
    @discardableResult
    func addNote(to nodeID: UUID, text: String = "", undoManager: UndoManager?) -> UUID? {
        guard let node = map.node(withID: nodeID) else { return nil }
        let attachment = Attachment(kind: .markdown, title: defaultTitle(.markdown, on: node.id, in: node))
        return addAttachment(attachment, to: nodeID, content: MarkdownNote.data(text), actionName: "Add Note",
                             undoManager: undoManager) ? attachment.id : nil
    }

    /// Handwritten note (PencilKit drawing) on `nodeID`, added now. Without
    /// `content` it starts empty; the editor uses `startDrawing` instead.
    @discardableResult
    func addDrawing(to nodeID: UUID, content: Data? = nil, undoManager: UndoManager?) -> UUID? {
        guard let node = map.node(withID: nodeID) else { return nil }
        let attachment = Attachment(kind: .drawing, title: defaultTitle(.drawing, on: node.id, in: node))
        return addAttachment(attachment, to: nodeID, content: content ?? HandwrittenNote.emptyData,
                             actionName: "Add Handwritten Note", undoManager: undoManager) ? attachment.id : nil
    }

    /// "Note", "Note 2", … / "Handwritten Note", … counting drafts too.
    func defaultTitle(_ kind: AttachmentKind, on nodeID: UUID, in node: Node) -> String {
        let count = node.attachments.filter { $0.kind == kind }.count
            + attachmentDrafts.values.filter { $0.nodeID == nodeID && $0.attachment.kind == kind }.count
        switch kind {
        case .drawing: return HandwrittenNote.defaultTitle(index: count)
        default: return count == 0 ? "Note" : "Note \(count + 1)"
        }
    }

    /// Removes the attachment (its bytes stay in the store for undo). A
    /// draft is just dropped (no undo step). Default step names: "Remove
    /// Note" / "Remove Handwritten Note" / "Remove File".
    @discardableResult
    func removeAttachment(_ id: UUID, actionName: String? = nil, undoManager: UndoManager?) -> Bool {
        if attachmentDrafts[id] != nil {
            attachmentDrafts[id] = nil
            return true
        }
        let name: String
        switch attachment(id)?.kind {
        case .markdown: name = "Remove Note"
        case .drawing: name = "Remove Handwritten Note"
        case .file: name = "Remove File"
        case nil: name = "Remove Attachment"
        }
        guard let edits = try? map.removeAttachmentEdits(id), !edits.isEmpty else { return false }
        return perform(edits, actionName: actionName ?? name, undoManager: undoManager)
    }

    @discardableResult
    func renameAttachment(_ id: UUID, to title: String, undoManager: UndoManager?) -> Bool {
        if var draft = attachmentDrafts[id] {
            guard draft.attachment.title != title else { return false }
            draft.attachment.title = title
            attachmentDrafts[id] = draft
            return true
        }
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
        // Read-only map (WP15): note text / drawings do not change.
        guard admitsContentChange(actionName, undoManager: undoManager) else { return false }
        if let draft = attachmentDrafts[attachmentID] {
            return writeDraftContent(data, draft: draft, undoManager: undoManager, now: now)
        }
        guard let attachment = attachment(attachmentID), Attachment.isValidFileName(attachment.fileName),
              decryptedContent(of: attachment) != data,
              // A locked note is written encrypted (and not at all while locked).
              let data = storedBytes(data, for: attachment) else { return false }
        let fileName = attachment.fileName
        if coalescing, let undoManager, let last = lastContentStep, last.fileName == fileName,
           last.manager == ObjectIdentifier(undoManager), !undoManager.isUndoing, !undoManager.isRedoing,
           !undoManager.canRedo, last.actionName == actionName || last.isCreation,
           undoManager.undoActionName == last.actionName,
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
            : ContentStepKey(fileName: fileName, manager: ObjectIdentifier(undoManager), time: now,
                             actionName: actionName)
        return true
    }
}
