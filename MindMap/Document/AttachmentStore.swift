import Foundation
import Observation

/// Contents of the package's `attachments/` folder for one open document
/// (shared by the macOS `MindMapDocument` and the iPad `MindMapUIDocument`).
///
/// - Files of the package as last read/saved stay `FileWrapper`s and are
///   reused on save, so unchanged files are not rewritten.
/// - Writes are kept in memory (`pending`) and merged into the package on
///   the next save; the caller marks the document dirty (undo registration).
/// - Orphans (files no attachment refers to) are left out of the saved
///   package. Their bytes stay in memory when this session knew them, so
///   undoing a removal (or a topic delete) restores the file on the next save.
///
/// Used on the main thread; `prepareSave` runs there too (document snapshot),
/// the returned wrappers are immutable and safe to write from any thread.
@Observable
final class AttachmentStore {
    @ObservationIgnored private var base: [String: FileWrapper] = [:]
    @ObservationIgnored private var pending: [String: Data] = [:]
    @ObservationIgnored private var retained: [String: Data] = [:]
    /// Names referenced at load or written since: only these can come back
    /// through undo, so only their bytes are retained once orphaned.
    @ObservationIgnored private var sessionNames: Set<String> = []

    /// Bumped on every change of a file (editors reload on external changes).
    private(set) var revisions: [String: Int] = [:]

    init() {}

    /// - Parameters:
    ///   - package: the `.mindmap` directory wrapper (its `attachments/` is used).
    ///   - referenced: file names the loaded map refers to.
    init(package: FileWrapper?, referenced: Set<String> = []) {
        reset(package: package, referenced: referenced)
    }

    /// Replaces everything with the package's files (open / revert).
    func reset(package: FileWrapper?, referenced: Set<String> = []) {
        let folder = package?.fileWrappers?[MindMapPackage.attachmentsFolderName]
        base = folder?.isDirectory == true ? (folder?.fileWrappers ?? [:]).filter { $0.value.isRegularFile } : [:]
        let changed = Set(revisions.keys).union(base.keys).union(pending.keys)
        pending = [:]
        retained = [:]
        sessionNames = referenced
        for name in changed { revisions[name, default: 0] += 1 }
    }

    // MARK: Access

    func data(for fileName: String) -> Data? {
        if let data = pending[fileName] { return data }
        if let wrapper = base[fileName] { return wrapper.regularFileContents }
        return retained[fileName]
    }

    func contains(_ fileName: String) -> Bool {
        pending[fileName] != nil || base[fileName] != nil || retained[fileName] != nil
    }

    func revision(of fileName: String) -> Int { revisions[fileName] ?? 0 }

    /// Files written since the last save (or load).
    var hasPendingChanges: Bool { !pending.isEmpty }

    /// Stores new content for `fileName` (in memory until the next save).
    /// Invalid names (folders, hidden files) are ignored.
    @discardableResult
    func write(_ data: Data, to fileName: String) -> Bool {
        guard Attachment.isValidFileName(fileName) else { return false }
        pending[fileName] = data
        sessionNames.insert(fileName)
        revisions[fileName, default: 0] += 1
        return true
    }

    // MARK: Save

    /// Children of the `attachments/` folder to save: every referenced file
    /// (pending content as a new wrapper, unchanged files reused as-is),
    /// orphans left out. Afterwards the result is the new base.
    func prepareSave(referencing names: Set<String>) -> [String: FileWrapper] {
        var children: [String: FileWrapper] = [:]
        for name in names where Attachment.isValidFileName(name) {
            if let data = pending[name] {
                children[name] = Self.wrapper(data, name: name)
            } else if let wrapper = base[name] {
                // Reused wrappers keep their names (see `MindMapPackage`).
                children[name] = wrapper
            } else if let data = retained[name] {
                children[name] = Self.wrapper(data, name: name)
            }
        }
        // Orphans: keep the bytes in memory for undo, drop them from the package.
        for (name, wrapper) in base where children[name] == nil && sessionNames.contains(name) && retained[name] == nil {
            if let data = wrapper.regularFileContents { retained[name] = data }
        }
        for (name, data) in pending where children[name] == nil {
            retained[name] = data
        }
        for name in children.keys { retained[name] = nil }
        base = children
        pending = [:]
        return children
    }

    private static func wrapper(_ data: Data, name: String) -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = name
        return wrapper
    }
}
