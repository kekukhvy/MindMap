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
        // step (marks the document dirty again), as on macOS. A locked map
        // is written encrypted; a sealed one (not decrypted) unchanged.
        let wrapper = try model.savePlan().fileWrapper(existing: package)
        package = wrapper
        return wrapper
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let wrapper = contents as? FileWrapper else { throw MindMapPackage.PackageError.notADirectory }
        if hasLoaded {
            // Revert (file changed elsewhere): old undo steps no longer apply.
            undoManager?.removeAllActions()
        }
        try model.load(package: wrapper)
        package = wrapper
        hasLoaded = true
    }

    /// The file was replaced (library sync, another device) after this
    /// document last read or wrote it, and the change never reached it as a
    /// file presenter (e.g. written while the app was suspended).
    var isOutdated: Bool {
        guard let known = fileModificationDate,
              let onDisk = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        else { return false }
        return onDisk > known
    }

    /// Reads the file again when it changed unnoticed (like UIDocument's
    /// own revert on a reported change, unsaved changes included).
    func revertIfOutdated() async {
        guard isOutdated else { return }
        _ = await revert(toContentsOf: fileURL)
    }

    /// Never writes a stale map over a newer file (autosave, close, Save
    /// Now): reverts instead.
    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation,
                       completionHandler: ((Bool) -> Void)? = nil) {
        guard saveOperation == .forOverwriting, url == fileURL, isOutdated else {
            return super.save(to: url, for: saveOperation, completionHandler: completionHandler)
        }
        revert(toContentsOf: fileURL) { completionHandler?($0) }
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
