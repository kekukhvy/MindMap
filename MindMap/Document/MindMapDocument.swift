import SwiftUI
import UniformTypeIdentifiers

/// Reference document (class) so the @Observable `MindMapModel` is edited in
/// place and every change goes through the environment UndoManager — which
/// is exactly how ReferenceFileDocument detects unsaved changes.
final class MindMapDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.mindMap] }
    static var writableContentTypes: [UTType] { [.mindMap] }

    let model: MindMapModel

    init(map: MindMap = MindMap()) {
        model = MindMapModel(map: map)
    }

    required init(configuration: ReadConfiguration) throws {
        model = MindMapModel(map: try MindMapPackage.read(configuration.file))
    }

    /// Called on the main thread when saving (incl. autosave).
    func snapshot(contentType: UTType) throws -> MindMap {
        model.breakCoalescing()
        return model.map
    }

    func fileWrapper(snapshot: MindMap, configuration: WriteConfiguration) throws -> FileWrapper {
        try MindMapPackage.fileWrapper(for: snapshot, existing: configuration.existingFile)
    }
}
