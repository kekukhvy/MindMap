import Foundation

/// Images pasted or dropped into a Markdown note (see `NoteImage`).
extension MindMapModel {
    /// Stores `data` as an image of the note `attachmentID` and returns its
    /// Markdown link, ready to insert into the note text. nil (nothing
    /// stored) for a locked note, a read-only map, a note that is not Markdown
    /// or data that is not an image. The caller inserts the link, which is
    /// the undoable, dirty-marking step; the file is kept as long as the
    /// note exists.
    func addNoteImage(_ data: Data, to attachmentID: UUID) -> String? {
        guard !isReadOnly, let attachment = attachment(attachmentID), attachment.kind == .markdown,
              !attachment.isLocked, let image = NoteImage.storable(data) else { return nil }
        let fileName = NoteImage.fileName(noteID: attachment.id, fileExtension: image.fileExtension)
        guard attachmentStore.write(image.data, to: fileName) else { return nil }
        return NoteImage.link(for: fileName)
    }
}
