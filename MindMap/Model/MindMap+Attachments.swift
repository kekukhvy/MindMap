import Foundation

/// Attachment queries and edit builders. All list changes are one
/// `.set(.attachments)` tree edit, so undo restores the exact list.
extension MindMap {
    /// The attachment with `id` and the topic holding it.
    func attachment(withID id: UUID) -> (nodeID: UUID, attachment: Attachment)? {
        for tree in trees {
            if let found = tree.findAttachment(id) { return found }
        }
        return nil
    }

    /// Every attachment in the map (main tree, then floating topics).
    var allAttachments: [Attachment] {
        trees.flatMap(\.allAttachments)
    }

    /// File names in `attachments/` that the map refers to (= files to keep).
    var referencedAttachmentFileNames: Set<String> {
        Set(allAttachments.map(\.fileName).filter(Attachment.isValidFileName))
    }

    /// The names among `fileNames` that are images of a Markdown note of this
    /// map (`NoteImage`): files to keep although no attachment lists them.
    /// A locked note keeps only its sealed images (`.enc`), any other only its plain ones.
    func noteImageNames<Names: Sequence>(in fileNames: Names) -> Set<String> where Names.Element == String {
        let notes = allAttachments.filter { $0.kind == .markdown }
        return Set(fileNames.filter { name in
            notes.contains { name.hasPrefix(NoteImage.ownerPrefix(of: $0.id)) && NoteImage.isSealed(name) == $0.isLocked }
        })
    }

    func attachmentListEdits(for nodeID: UUID, _ change: (inout [Attachment]) throws -> Void) throws -> [MapEdit] {
        guard let node = node(withID: nodeID) else { throw TreeEditError.nodeNotFound }
        var list = node.attachments
        try change(&list)
        guard list != node.attachments else { return [] }
        return [.tree(.set(id: nodeID, .attachments(list)))]
    }

    func addAttachmentEdits(_ attachment: Attachment, to nodeID: UUID, at index: Int? = nil) throws -> [MapEdit] {
        guard self.attachment(withID: attachment.id) == nil,
              allAttachments.allSatisfy({ $0.fileName != attachment.fileName }) else {
            throw TreeEditError.duplicateID
        }
        return try attachmentListEdits(for: nodeID) { list in
            list.insert(attachment, at: min(max(index ?? list.count, 0), list.count))
        }
    }

    func updateAttachmentEdits(_ id: UUID, _ change: (inout Attachment) -> Void) throws -> [MapEdit] {
        guard let found = attachment(withID: id) else { throw TreeEditError.nodeNotFound }
        return try attachmentListEdits(for: found.nodeID) { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[index])
            list[index].id = id
        }
    }

    func removeAttachmentEdits(_ id: UUID) throws -> [MapEdit] {
        guard let found = attachment(withID: id) else { throw TreeEditError.nodeNotFound }
        return try attachmentListEdits(for: found.nodeID) { $0.removeAll { $0.id == id } }
    }

    /// Moves the attachment to `index` within its topic's list (clamped).
    func moveAttachmentEdits(_ id: UUID, to index: Int) throws -> [MapEdit] {
        guard let found = attachment(withID: id) else { throw TreeEditError.nodeNotFound }
        return try attachmentListEdits(for: found.nodeID) { list in
            guard let from = list.firstIndex(where: { $0.id == id }) else { return }
            let item = list.remove(at: from)
            list.insert(item, at: min(max(index, 0), list.count))
        }
    }
}

extension Node {
    func findAttachment(_ id: UUID) -> (nodeID: UUID, attachment: Attachment)? {
        if let attachment = attachments.first(where: { $0.id == id }) { return (self.id, attachment) }
        for child in children {
            if let found = child.findAttachment(id) { return found }
        }
        return nil
    }

    /// Attachments of this subtree (pre-order).
    var allAttachments: [Attachment] {
        attachments + children.flatMap(\.allAttachments)
    }
}
