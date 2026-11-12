import SwiftUI
import UniformTypeIdentifiers

/// Reference document (class) so the @Observable `MindMapModel` is edited in
/// place and every change goes through the environment UndoManager — which
/// is exactly how ReferenceFileDocument detects unsaved changes (attachment
/// content edits register undo steps too, see `MindMapModel+Attachments`).
final class MindMapDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.mindMap] }
    static var writableContentTypes: [UTType] { [.mindMap] }

    /// What one save writes: the map plus the prepared `attachments/` files.
    struct Snapshot {
        var map: MindMap
        var attachments: [String: FileWrapper]
    }

    let model: MindMapModel

    init(map: MindMap = MindMap()) {
        model = MindMapModel(map: map)
    }

    required init(configuration: ReadConfiguration) throws {
        let map = try MindMapPackage.read(configuration.file)
        model = MindMapModel(map: map, attachmentStore: AttachmentStore(
            package: configuration.file, referenced: map.referencedAttachmentFileNames))
    }

    /// Called on the main thread when saving (incl. autosave): the store
    /// work happens here; `fileWrapper(snapshot:)` may run on another thread.
    func snapshot(contentType: UTType) throws -> Snapshot {
        model.breakCoalescing()
        let map = model.map
        return Snapshot(map: map, attachments: model.attachmentStore.prepareSave(
            referencing: map.referencedAttachmentFileNames))
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        try Self.package(for: snapshot, existing: configuration.existingFile)
    }

    static func package(for snapshot: Snapshot, existing: FileWrapper?) throws -> FileWrapper {
        try MindMapPackage.fileWrapper(for: snapshot.map, existing: existing, attachments: snapshot.attachments)
    }
}
