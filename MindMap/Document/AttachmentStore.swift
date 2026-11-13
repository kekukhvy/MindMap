import Foundation
import Observation

/// Contents of the package's `attachments/` folder for one open document
/// (shared by the macOS `MindMapDocument` and the iPad `MindMapUIDocument`).
///
/// - Files of the package as last read/saved stay `FileWrapper`s and are
///   reused on save, so unchanged files are not rewritten.
/// - Writes are kept outside the package (`pending`) and merged into it on
///   the next save; the caller marks the document dirty (undo registration).
///   Small writes (notes, drawings) are `Data`; imported files are copied
///   (streamed / APFS-cloned, never read into memory) into a private
///   scratch folder and saved from there through lazily reading wrappers.
/// - Orphans (files no attachment refers to) are left out of the saved
///   package. When this session knew them they are retained so undoing a
///   removal (or a topic delete) restores the file on the next save: small
///   ones as `Data`, large ones (> `largeFileThreshold`) copied to the
///   scratch folder (the package file itself disappears with that save).
///
/// Used on the main thread; `prepareSave` runs there too (document snapshot),
/// the returned wrappers are immutable and safe to write from any thread.
/// Scratch files live until the store is released (saves may still read them).
@Observable
final class AttachmentStore {
    /// Content of one file held outside the package.
    private enum Blob {
        case data(Data)
        /// A file in `scratchDirectory`, never loaded by the store.
        case file(URL)

        var data: Data? {
            switch self {
            case let .data(data): return data
            case let .file(url): return try? Data(contentsOf: url, options: .mappedIfSafe)
            }
        }
    }

    /// Orphans larger than this are retained on disk instead of in memory.
    static let largeFileThreshold = 1 << 20

    @ObservationIgnored private var base: [String: FileWrapper] = [:]
    @ObservationIgnored private var pending: [String: Blob] = [:]
    @ObservationIgnored private var retained: [String: Blob] = [:]
    /// Names referenced at load or written since: only these can come back
    /// through undo, so only their bytes are retained once orphaned.
    @ObservationIgnored private var sessionNames: Set<String> = []
    /// Private temp folder of this store (imports, large retained orphans).
    @ObservationIgnored let scratchDirectory: URL
    /// Locked map (WP12): no plaintext may stay on disk, so imported files
    /// and large retained orphans are held in memory instead of the
    /// scratch folder (files already there are read in and deleted).
    @ObservationIgnored var keepsContentInMemory = false {
        didSet { if keepsContentInMemory && !oldValue { moveScratchFilesIntoMemory() } }
    }
    /// Plaintext of a note that was locked (its old file name): retained
    /// for undo in memory only, never spilled to the scratch folder.
    @ObservationIgnored private var sensitiveNames: Set<String> = []
    /// Saved files whose wrapper still reads lazily from the scratch folder.
    @ObservationIgnored private var scratchBacked: [String: URL] = [:]

    /// Bumped on every change of a file (editors reload on external changes).
    private(set) var revisions: [String: Int] = [:]

    init() {
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMap Attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// - Parameters:
    ///   - package: the `.mindmap` directory wrapper (its `attachments/` is used).
    ///   - referenced: file names the loaded map refers to.
    convenience init(package: FileWrapper?, referenced: Set<String> = []) {
        self.init()
        reset(package: package, referenced: referenced)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    /// Replaces everything with the package's files (open / revert).
    func reset(package: FileWrapper?, referenced: Set<String> = []) {
        let folder = package?.fileWrappers?[MindMapPackage.attachmentsFolderName]
        base = folder?.isDirectory == true ? (folder?.fileWrappers ?? [:]).filter { $0.value.isRegularFile } : [:]
        let changed = Set(revisions.keys).union(base.keys).union(pending.keys)
        pending = [:]
        retained = [:]
        sensitiveNames = []
        scratchBacked = [:]
        sessionNames = referenced.union(base.keys.filter { $0.contains(NoteImage.nameMarker) })
        for name in changed { revisions[name, default: 0] += 1 }
    }

    // MARK: Access

    /// The file's bytes (memory-mapped where possible). Prefer `copy(_:to:)`
    /// for imported files, which may be large.
    func data(for fileName: String) -> Data? {
        if let blob = pending[fileName] { return blob.data }
        if let wrapper = base[fileName] { return wrapper.regularFileContents }
        return retained[fileName]?.data
    }

    /// Every file name this store knows (package, pending, retained).
    private var knownNames: Set<String> {
        Set(base.keys).union(pending.keys).union(retained.keys)
    }

    /// Image files (`NoteImage`) of the Markdown note `noteID`, with their bytes.
    func noteImages(of noteID: UUID) -> [String: Data] {
        let prefix = NoteImage.ownerPrefix(of: noteID)
        var images: [String: Data] = [:]
        for name in knownNames where name.hasPrefix(prefix) {
            if let data = data(for: name) { images[name] = data }
        }
        return images
    }

    func contains(_ fileName: String) -> Bool {
        pending[fileName] != nil || base[fileName] != nil || retained[fileName] != nil
    }

    /// Size in bytes, nil if the file is unknown.
    func size(of fileName: String) -> Int? {
        func size(_ blob: Blob) -> Int? {
            switch blob {
            case let .data(data): return data.count
            case let .file(url):
                return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            }
        }
        if let blob = pending[fileName] { return size(blob) }
        if let wrapper = base[fileName] { return Self.size(of: wrapper) }
        return retained[fileName].flatMap(size)
    }

    /// Writes the file to `destination` (which must not exist) without
    /// loading imported/large files into memory.
    func copy(_ fileName: String, to destination: URL) throws {
        if let blob = pending[fileName] ?? (base[fileName] == nil ? retained[fileName] : nil) {
            switch blob {
            case let .data(data): try data.write(to: destination)
            case let .file(url): try FileManager.default.copyItem(at: url, to: destination)
            }
        } else if let wrapper = base[fileName] {
            try wrapper.write(to: destination, options: [], originalContentsURL: nil)
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    func revision(of fileName: String) -> Int { revisions[fileName] ?? 0 }

    /// Files written since the last save (or load).
    var hasPendingChanges: Bool { !pending.isEmpty }

    /// Bytes this store holds in memory (pending + retained `Data`);
    /// imported and large files are not counted (they stay on disk).
    var inMemoryByteCount: Int {
        (Array(pending.values) + Array(retained.values)).reduce(0) { total, blob in
            if case let .data(data) = blob { return total + data.count }
            return total
        }
    }

    /// Stores new content for `fileName` (in memory until the next save).
    /// Invalid names (folders, hidden files) are ignored.
    @discardableResult
    func write(_ data: Data, to fileName: String) -> Bool {
        guard Attachment.isValidFileName(fileName) else { return false }
        set(.data(data), for: fileName)
        return true
    }

    /// A fresh, unique location inside the scratch folder for one file
    /// (the folder is created; the file itself is not). Thread-safe.
    static func makeScratchURL(in scratch: URL, name: String) throws -> URL {
        let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name.isEmpty ? "file" : name, isDirectory: false)
    }

    /// Takes `url` (a file the caller copied into `scratchDirectory`, see
    /// `AttachmentImporter`) as the new content of `fileName`. The file is
    /// referenced, not read.
    @discardableResult
    func adoptScratchFile(_ url: URL, as fileName: String) -> Bool {
        guard Attachment.isValidFileName(fileName),
              url.standardizedFileURL.path.hasPrefix(scratchDirectory.standardizedFileURL.path) else { return false }
        if keepsContentInMemory {
            guard let data = try? Data(contentsOf: url) else { return false }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            set(.data(data), for: fileName)
            return true
        }
        set(.file(url), for: fileName)
        return true
    }

    /// The plaintext of `fileName` must never be written to the scratch
    /// folder (a note that is being locked).
    func markSensitive(_ fileName: String) {
        sensitiveNames.insert(fileName)
        for name in [fileName] {
            if case let .file(url)? = pending[name], let data = try? Data(contentsOf: url) {
                pending[name] = .data(data)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            if case let .file(url)? = retained[name], let data = try? Data(contentsOf: url) {
                retained[name] = .data(data)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
    }

    /// Files of this store currently in the scratch folder (tests).
    var scratchFileCount: Int {
        scratchBacked.count + (Array(pending.values) + Array(retained.values)).filter {
            if case .file = $0 { return true }
            return false
        }.count
    }

    private func moveScratchFilesIntoMemory() {
        for (name, url) in scratchBacked {
            if let data = try? Data(contentsOf: url) {
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = name
                base[name] = wrapper
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        scratchBacked = [:]
        for (name, blob) in pending {
            if case let .file(url) = blob, let data = try? Data(contentsOf: url) {
                pending[name] = .data(data)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        for (name, blob) in retained {
            if case let .file(url) = blob, let data = try? Data(contentsOf: url) {
                retained[name] = .data(data)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
    }

    private func set(_ blob: Blob, for fileName: String) {
        pending[fileName] = blob
        sessionNames.insert(fileName)
        revisions[fileName, default: 0] += 1
    }

    // MARK: Save

    /// Children of the `attachments/` folder to save: every referenced file
    /// (pending content as a new wrapper, unchanged files reused as-is),
    /// orphans left out. Afterwards the result is the new base.
    /// The save of `map`: its attachments plus the images of its notes.
    func prepareSave(for map: MindMap) -> [String: FileWrapper] {
        prepareSave(referencing: map.referencedAttachmentFileNames.union(map.noteImageNames(in: knownNames)))
    }

    func prepareSave(referencing names: Set<String>) -> [String: FileWrapper] {
        var children: [String: FileWrapper] = [:]
        var backed: [String: URL] = [:]
        for name in names where Attachment.isValidFileName(name) {
            if let blob = pending[name] ?? (base[name] == nil ? retained[name] : nil) {
                children[name] = Self.wrapper(blob, name: name)
                if case let .file(url) = blob { backed[name] = url }
            } else if let wrapper = base[name] {
                // Reused wrappers keep their names (see `MindMapPackage`).
                children[name] = wrapper
                backed[name] = scratchBacked[name]
            }
        }
        // Orphans: keep their bytes for undo (memory / scratch), drop them from the package.
        for (name, wrapper) in base where children[name] == nil && sessionNames.contains(name) && retained[name] == nil {
            if let blob = retain(wrapper, name: name) { retained[name] = blob }
        }
        for (name, blob) in pending where children[name] == nil {
            retained[name] = blob
        }
        for name in children.keys { retained[name] = nil }
        base = children
        scratchBacked = backed
        pending = [:]
        return children
    }

    /// Copy of an orphaned package file that survives the package losing it.
    private func retain(_ wrapper: FileWrapper, name: String) -> Blob? {
        if !keepsContentInMemory, !sensitiveNames.contains(name),
           (Self.size(of: wrapper) ?? 0) > Self.largeFileThreshold,
           let url = try? Self.makeScratchURL(in: scratchDirectory, name: name),
           (try? wrapper.write(to: url, options: [], originalContentsURL: nil)) != nil {
            return .file(url)
        }
        return wrapper.regularFileContents.map(Blob.data)
    }

    private static func size(of wrapper: FileWrapper) -> Int? {
        if let size = wrapper.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber { return size.intValue }
        return wrapper.regularFileContents?.count
    }

    private static func wrapper(_ blob: Blob, name: String) -> FileWrapper? {
        let wrapper: FileWrapper
        switch blob {
        case let .data(data):
            wrapper = FileWrapper(regularFileWithContents: data)
        case let .file(url):
            // Reads lazily (memory-mapped) when the package is written.
            guard let fileWrapper = try? FileWrapper(url: url, options: []) else { return nil }
            wrapper = fileWrapper
        }
        wrapper.preferredFilename = name
        return wrapper
    }
}
