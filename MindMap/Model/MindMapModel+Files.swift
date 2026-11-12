import CoreGraphics
import Foundation

/// Imported file attachments (WP6). The copy made by `AttachmentImporter`
/// is adopted by the store as-is (no bytes in memory); one undo step each.
extension MindMapModel {
    /// Attaches `file` (copied into the store's scratch folder) to `nodeID`.
    @discardableResult
    func addFile(_ file: ImportedFile, to nodeID: UUID, at index: Int? = nil, undoManager: UndoManager?) -> UUID? {
        let attachment = Attachment.file(originalName: file.originalName)
        guard (try? map.addAttachmentEdits(attachment, to: nodeID, at: index)) != nil,
              attachmentStore.adoptScratchFile(file.url, as: attachment.fileName) else { return nil }
        return addAttachment(attachment, to: nodeID, at: index, actionName: "Attach File",
                             undoManager: undoManager) ? attachment.id : nil
    }

    /// Copies the file at `url` (blocking) and attaches it to `nodeID`.
    @discardableResult
    func importFile(at url: URL, to nodeID: UUID, undoManager: UndoManager?) throws -> UUID? {
        let file = try AttachmentImporter.copy(url, into: attachmentStore.scratchDirectory)
        return addFile(file, to: nodeID, undoManager: undoManager)
    }

    /// New floating topic at `position`, named after the file (without its
    /// extension) and holding it: one "Add File Topic" undo step.
    @discardableResult
    func addFileTopic(_ file: ImportedFile, at position: CGPoint,
                      undoManager: UndoManager?) -> (topic: UUID, attachment: UUID)? {
        let attachment = Attachment.file(originalName: file.originalName)
        let node = Node(text: AttachmentFileName.topicText(forTitle: attachment.title), attachments: [attachment])
        guard Attachment.isValidFileName(attachment.fileName),
              attachmentStore.adoptScratchFile(file.url, as: attachment.fileName),
              perform(map.addFloatingEdits(node, at: position), actionName: "Add File Topic",
                      undoManager: undoManager) else { return nil }
        return (node.id, attachment.id)
    }

    /// Temp copy of the attachment's file named after its title (share,
    /// export, open in another app, QuickLook). Edits made to the copy are
    /// NOT written back into the map. A new folder per call.
    func exportCopy(of attachmentID: UUID) throws -> URL {
        guard let attachment = attachment(attachmentID) else { throw CocoaError(.fileNoSuchFile) }
        let url = try AttachmentStore.makeScratchURL(in: Self.exportDirectory,
                                                     name: AttachmentFileName.exportName(for: attachment))
        try attachmentStore.copy(attachment.fileName, to: url)
        return url
    }

    /// Exported copies outlive the document (another app may still have one
    /// open); the system purges the temporary folder.
    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MindMap Shared", isDirectory: true)
    }
}
