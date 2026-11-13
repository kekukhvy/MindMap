import Foundation

/// Moving maps between the library and `.mindmap` files (WP14b): Import to
/// Library, Move to Library, Export as File…, Duplicate, Rename. Works on
/// whole packages, so locked maps stay encrypted (their `lock.json` +
/// `.enc` files are copied as they are) and attachments / locked notes come
/// along unchanged. Plain maps get their `title` set (the library has no
/// file names the user sees).
extension LibraryMapStore {
    /// Copies the `.mindmap` package at `url` into the library as a new
    /// map named `title` (default: the file name).
    @discardableResult
    func importPackage(at url: URL, title: String? = nil) throws -> MapSummary {
        let wrapper = try MapPackageIO.read(url)
        let name = title ?? MapPaths.displayName(of: url)
        return try add(wrapper, title: name)
    }

    /// A copy of library map `id` ("<title> copy").
    @discardableResult
    func duplicateMap(_ id: UUID) throws -> MapSummary {
        guard let url = cache.packageURL(for: id) else { throw CocoaError(.fileNoSuchFile) }
        let summary = maps().first { $0.location == .library(id) }
        let title = uniqueTitle(base: (summary?.title ?? MapPaths.displayName(of: url)) + " copy")
        return try add(try MapPackageIO.read(url), title: title)
    }

    /// The package of library map `id` for Export as File… (a copy in
    /// memory: the cached package can change while the panel is open).
    func exportWrapper(_ id: UUID) throws -> FileWrapper {
        guard let url = cache.packageURL(for: id) else { throw CocoaError(.fileNoSuchFile) }
        return try MapPackageIO.read(url)
    }

    /// Writes library map `id` as a `.mindmap` file at `destination`.
    func export(_ id: UUID, to destination: URL) throws {
        try MapPackageIO.write(try exportWrapper(id), to: destination)
    }

    /// A new empty map ("Untitled", "Untitled 2", …; central topic
    /// "Central Topic") — New Map in library mode.
    @discardableResult
    func createUntitledMap() throws -> MapSummary {
        let title = uniqueTitle(base: UntitledName.base)
        var map = MindMap()
        map.title = title
        return try importMap(map)
    }

    /// `base`, or "base 2", "base 3", … if a library map is already called so.
    func uniqueTitle(base: String) -> String {
        let taken = Set(maps().map { $0.title.lowercased() })
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) \(index)"
            if !taken.contains(name.lowercased()) { return name }
            index += 1
        }
    }

    /// Adds an in-memory package as library map `id` (WP13 sample maps,
    /// whose links to each other need the IDs up front).
    @discardableResult
    func importWrapper(_ wrapper: FileWrapper, title: String, id: UUID = UUID()) throws -> MapSummary {
        try add(wrapper, title: title, id: id)
    }

    /// Adds a package (plain: `title` written into its map) as a new map.
    private func add(_ wrapper: FileWrapper, title: String, id: UUID = UUID()) throws -> MapSummary {
        let isLocked = wrapper.fileWrappers?[LockHeader.fileName] != nil
        if !isLocked, let data = wrapper.fileWrappers?[MindMapPackage.mapFileName]?.regularFileContents {
            var map = try MindMapPackage.decode(data)
            map.title = title
            MapPackageIO.replace(MindMapPackage.mapFileName, in: wrapper, with: try MindMapPackage.encode(map))
        }
        try cache.writePackage(wrapper, for: id, title: title)
        sync.checkForLocalChanges(id)
        sync.onLibraryChanged?()
        return MapSummary(location: .library(id), title: title, modified: Date(), isLocked: isLocked)
    }
}

extension LibraryCache {
    /// Renames the package of map `id` after `title` (window titles show
    /// the file name). Coordinated, so an open document follows the move.
    /// Returns the (new) package URL.
    @discardableResult
    func renamePackage(of id: UUID, toTitle title: String) throws -> URL? {
        guard let url = packageURL(for: id) else { return nil }
        let name = MapPaths.fileNameBase(forTopic: title) + "." + MapPaths.fileExtension
        guard name != url.lastPathComponent else { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        try MapPackageIO.move(url, to: target)
        return target
    }

    /// Title of a plain map (`LibraryTitle`), nil when locked / unreadable.
    func plainTitle(of id: UUID) -> String? {
        guard let url = packageURL(for: id),
              let data = try? Data(contentsOf: url.appendingPathComponent(MindMapPackage.mapFileName)),
              let map = try? MindMapPackage.decode(data) else { return nil }
        return LibraryTitle.title(of: map)
    }
}

/// Package file helpers (coordinated, security-scoped where needed).
enum MapPackageIO {
    /// The package at `url`, fully read into memory.
    static func read(_ url: URL) throws -> FileWrapper {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<FileWrapper, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try FileWrapper(url: target, options: .immediate) }
        }
        if let coordinationError { throw coordinationError }
        let wrapper = try result.get()
        guard wrapper.isDirectory, wrapper.fileWrappers?[MindMapPackage.mapFileName] != nil
            || wrapper.fileWrappers?[LockHeader.fileName] != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return wrapper
    }

    /// Writes `wrapper` as a package at `url` (replacing what is there).
    static func write(_ wrapper: FileWrapper, to url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try wrapper.write(to: target, options: [], originalContentsURL: nil)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// Coordinated move (open documents follow).
    static func move(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination,
                               options: .forReplacing, error: &coordinationError) { from, to in
            do {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    /// Moves the file to the Trash (Move to Library); where there is no
    /// Trash (some iPad locations) it is deleted.
    static func trash(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var trashError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                         error: &coordinationError) { target in
            do {
                do {
                    try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                } catch let error as CocoaError where error.code == .featureUnsupported {
                    try FileManager.default.removeItem(at: target)
                }
            } catch {
                trashError = error
            }
        }
        if let error = coordinationError ?? trashError { throw error }
    }

    /// A free "<name> copy.mindmap" (or numbered) URL in `folder`.
    static func copyURL(for url: URL, in folder: URL) -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let name = UntitledName.next(existing: names, pathExtension: MapPaths.fileExtension,
                                     base: MapPaths.displayName(of: url) + " copy")
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    static func replace(_ name: String, in wrapper: FileWrapper, with data: Data) {
        if let old = wrapper.fileWrappers?[name] { wrapper.removeFileWrapper(old) }
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        wrapper.addFileWrapper(file)
    }
}

/// Settings ▸ Move Maps… (whole sets of maps between the stores).
@MainActor
enum LibraryMoves {
    struct Outcome: Equatable {
        var succeeded: [String] = []
        var failed: [String] = []
        /// Not removed from the library because they are open.
        var keptOpen: [String] = []

        func summary(verb: String) -> String {
            var parts = ["\(succeeded.count) map\(succeeded.count == 1 ? "" : "s") \(verb)."]
            if !failed.isEmpty { parts.append("Failed: " + failed.joined(separator: ", ") + ".") }
            if !keptOpen.isEmpty { parts.append("Still open, kept in the library: " + keptOpen.joined(separator: ", ") + ".") }
            return parts.joined(separator: " ")
        }
    }

    /// Imports `.mindmap` files; with `trashOriginals` the files go to the
    /// Trash once their copy is in the library.
    static func importFiles(_ urls: [URL], into store: LibraryMapStore, trashOriginals: Bool) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            let name = MapPaths.displayName(of: url)
            do {
                try store.importPackage(at: url)
                if trashOriginals { try MapPackageIO.trash(url) }
                outcome.succeeded.append(name)
            } catch {
                outcome.failed.append(name)
            }
        }
        return outcome
    }

    /// Writes every library map as "<Title>.mindmap" into `folder` (free
    /// names); with `removeFromLibrary` exported maps leave the library,
    /// except those `isOpen` reports as open in a window.
    static func exportAll(_ store: LibraryMapStore, to folder: URL, removeFromLibrary: Bool,
                          isOpen: (URL) -> Bool = { _ in false }) -> Outcome {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var outcome = Outcome()
        for map in store.maps() {
            guard case let .library(id) = map.location else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let fileName = UntitledName.next(existing: names, pathExtension: MapPaths.fileExtension,
                                             base: MapPaths.fileNameBase(forTopic: map.title))
            do {
                try store.export(id, to: folder.appendingPathComponent(fileName, isDirectory: true))
                outcome.succeeded.append(map.title)
                guard removeFromLibrary else { continue }
                if let url = store.packageURL(for: map.location), isOpen(url) {
                    outcome.keptOpen.append(map.title)
                } else {
                    try store.deleteMap(map.location)
                }
            } catch {
                outcome.failed.append(map.title)
            }
        }
        return outcome
    }
}
