import SwiftUI
import UniformTypeIdentifiers

/// Reference document (class) so the @Observable `MindMapModel` is edited in
/// place and every change goes through the environment UndoManager — which
/// is exactly how ReferenceFileDocument detects unsaved changes (attachment
/// content edits register undo steps too, see `MindMapModel+Attachments`).
/// A locked map (WP12) opens sealed (lock screen) and is saved encrypted;
/// see `MindMapModel.savePlan`.
final class MindMapDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.mindMap] }
    static var writableContentTypes: [UTType] { [.mindMap] }

    /// What one save writes: plain map + prepared `attachments/` files,
    /// the same encrypted, or a sealed package unchanged.
    typealias Snapshot = SavePlan

    let model: MindMapModel

    init(map: MindMap = MindMap()) {
        model = MindMapModel(map: map)
    }

    required init(configuration: ReadConfiguration) throws {
        model = MindMapModel()
        try model.load(package: configuration.file)
    }

    /// Called on the main thread when saving (incl. autosave): the store
    /// work happens here; `fileWrapper(snapshot:)` may run on another thread.
    func snapshot(contentType: UTType) throws -> Snapshot {
        model.savePlan()
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        try Self.package(for: snapshot, existing: configuration.existingFile)
    }

    static func package(for snapshot: Snapshot, existing: FileWrapper?) throws -> FileWrapper {
        try snapshot.fileWrapper(existing: existing)
    }
}
