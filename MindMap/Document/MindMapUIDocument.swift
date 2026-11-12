#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// iPadOS document (one per window, see `DocumentSession`). Same package
/// format as the macOS `MindMapDocument` (`MindMapPackage`). Dirty state and
/// autosave come from UIDocument observing its `undoManager`, which the
/// window sets to its own undo manager (the one the editor and the system
/// Edit menu use), so every model change marks the document edited.
final class MindMapUIDocument: UIDocument {
    let model = MindMapModel()
    /// Package as last read/written: unknown entries are reused on save;
    /// `attachments/` comes from the model's `AttachmentStore` (unchanged
    /// files reused, pending writes merged, orphans dropped).
    private var package: FileWrapper?
    private var hasLoaded = false

    override func contents(forType typeName: String) throws -> Any {
        // Main thread. A rename after an autosave must register its own
        // step (marks the document dirty again), as on macOS.
        model.breakCoalescing()
        let wrapper = try MindMapPackage.fileWrapper(for: model.map, store: model.attachmentStore, existing: package)
        package = wrapper
        return wrapper
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let wrapper = contents as? FileWrapper else { throw MindMapPackage.PackageError.notADirectory }
        let map = try MindMapPackage.read(wrapper)
        package = wrapper
        if hasLoaded {
            // Revert (file changed elsewhere): old undo steps no longer apply.
            undoManager?.removeAllActions()
        }
        hasLoaded = true
        model.replaceMap(map)
        model.attachmentStore.reset(package: wrapper, referenced: map.referencedAttachmentFileNames)
    }

    /// Keeps the version being edited when iCloud reports a conflict.
    func resolveConflictsKeepingCurrent() {
        guard documentState.contains(.inConflict) else { return }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) ?? [] {
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
    }
}
#endif
