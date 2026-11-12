import Foundation
import Observation

/// Value of an attachment window (macOS `WindowGroup(for:)`): which open
/// document (`MindMapModel.documentID`, per process) and which attachment.
/// Restored windows after a relaunch carry a stale document id and show a
/// "map not open" placeholder.
struct AttachmentWindowID: Codable, Hashable {
    var documentID: UUID
    var attachmentID: UUID
}

/// Documents with an open editor, so an attachment window edits the same
/// model / store and registers its undo steps on that document's undo
/// manager (which marks it dirty and gets it autosaved).
@MainActor
@Observable
final class OpenDocumentRegistry {
    static let shared = OpenDocumentRegistry()

    final class Entry {
        private(set) weak var model: MindMapModel?
        private(set) weak var undoManager: UndoManager?

        init(model: MindMapModel, undoManager: UndoManager?) {
            self.model = model
            self.undoManager = undoManager
        }
    }

    private(set) var entries: [UUID: Entry] = [:]

    func register(_ model: MindMapModel, undoManager: UndoManager?) {
        if let current = entries[model.documentID], current.model === model, current.undoManager === undoManager {
            return
        }
        entries[model.documentID] = Entry(model: model, undoManager: undoManager)
    }

    func unregister(_ model: MindMapModel) {
        guard entries[model.documentID]?.model === model else { return }
        entries[model.documentID] = nil
    }

    /// The live entry for `documentID` (nil once the document is closed).
    func entry(for documentID: UUID) -> Entry? {
        guard let entry = entries[documentID], entry.model != nil else { return nil }
        return entry
    }
}
