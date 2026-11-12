import Foundation
import UniformTypeIdentifiers

/// A file copied into an `AttachmentStore`'s scratch folder, ready to be
/// adopted as an attachment (`MindMapModel.addFile`).
struct ImportedFile: Equatable {
    /// Name the user knew the file by ("Q3 Report.pdf"; folders get ".zip").
    var originalName: String
    /// The copy (inside the scratch folder).
    var url: URL
}

/// Copies files that are being attached into a store's scratch folder.
///
/// Files are copied with `FileManager.copyItem` (APFS clone or streamed
/// copy; never read into memory) under file coordination (downloads iCloud
/// files first) and security-scoped access (picker / drop URLs). Folders and
/// packages (e.g. ".key") are attached as a ".zip" made by the system
/// (`NSFileCoordinator` `.forUploading`). The blocking `copy` functions are
/// meant for a background queue; the batch helpers call back on main.
enum AttachmentImporter {
    enum ImportError: LocalizedError {
        case noFile(String)

        var errorDescription: String? {
            switch self {
            case let .noFile(name): return "“\(name)” is not a file that can be attached."
            }
        }
    }

    // MARK: Blocking (any thread)

    /// Copies the file / folder at `source` (a picked, dropped or local URL).
    static func copy(_ source: URL, into scratch: URL, originalName: String? = nil) throws -> ImportedFile {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let name = originalName ?? source.lastPathComponent
        if isDirectory(source) { return try zip(source, originalName: name, into: scratch) }
        var result: Result<ImportedFile, Error> = .failure(ImportError.noFile(name))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges],
                                       error: &coordinationError) { readURL in
            result = Result { try place(readURL, originalName: name, into: scratch) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Copies an already readable local file / folder (e.g. a drag item's
    /// temporary file, valid only during its callback).
    static func copyReadable(_ url: URL, originalName: String, into scratch: URL) throws -> ImportedFile {
        if isDirectory(url) { return try zip(url, originalName: originalName, into: scratch) }
        return try place(url, originalName: originalName, into: scratch)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func place(_ url: URL, originalName: String, into scratch: URL) throws -> ImportedFile {
        let destination = try AttachmentStore.makeScratchURL(in: scratch, name: "content")
        try FileManager.default.copyItem(at: url, to: destination)
        guard !isDirectory(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.noFile(originalName)
        }
        return ImportedFile(originalName: originalName, url: destination)
    }

    private static func zip(_ folder: URL, originalName: String, into scratch: URL) throws -> ImportedFile {
        var result: Result<ImportedFile, Error> = .failure(ImportError.noFile(originalName))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading],
                                       error: &coordinationError) { zipURL in
            result = Result { try place(zipURL, originalName: originalName + ".zip", into: scratch) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    // MARK: Batches (call back on the main queue, results in input order)

    static func copy(_ urls: [URL], into scratch: URL,
                     completion: @escaping ([Result<ImportedFile, Error>]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let results = urls.map { url in Result { try copy(url, into: scratch) } }
            DispatchQueue.main.async { completion(results) }
        }
    }

    /// Drag & drop / clipboard items: a file URL when offered (Finder),
    /// else the item's file representation (Files, Photos, other apps).
    static func load(_ providers: [NSItemProvider], into scratch: URL,
                     completion: @escaping ([Result<ImportedFile, Error>]) -> Void) {
        let group = DispatchGroup()
        let box = ResultsBox(count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            load(provider, into: scratch) { result in
                box.set(index, result)
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(box.results) }
    }

    /// Whether the item stands for a file (not just a text / web-link
    /// snippet, which is not attached).
    static func isFileLike(_ provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return true }
        if provider.suggestedName != nil { return true }
        return provider.registeredTypeIdentifiers.contains { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
        }
    }

    private static func load(_ provider: NSItemProvider, into scratch: URL,
                             completion: @escaping (Result<ImportedFile, Error>) -> Void) {
        let fallback = { loadRepresentation(provider, into: scratch, completion: completion) }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return fallback() }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL, let file = try? copy(url, into: scratch) else { return fallback() }
            completion(.success(file))
        }
    }

    private static func loadRepresentation(_ provider: NSItemProvider, into scratch: URL,
                                           completion: @escaping (Result<ImportedFile, Error>) -> Void) {
        let types = provider.registeredTypeIdentifiers.filter { $0 != UTType.fileURL.identifier }
        guard let typeID = types.first(where: { UTType($0)?.conforms(to: .data) == true }) ?? types.first else {
            return completion(.failure(ImportError.noFile(provider.suggestedName ?? "Item")))
        }
        _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
            guard let url else {
                return completion(.failure(error ?? ImportError.noFile(provider.suggestedName ?? "Item")))
            }
            let name = originalName(suggested: provider.suggestedName, fileURL: url, typeID: typeID)
            // The temporary file is deleted when this callback returns: copy now.
            completion(Result { try copyReadable(url, originalName: name, into: scratch) })
        }
    }

    /// Suggested name (+ the type's extension if it has none), else the file's name.
    static func originalName(suggested: String?, fileURL: URL, typeID: String) -> String {
        guard let suggested, !suggested.isEmpty else { return fileURL.lastPathComponent }
        if AttachmentFileName.storedExtension(fromOriginalName: suggested) != nil { return suggested }
        let ext = fileURL.pathExtension.isEmpty ? UTType(typeID)?.preferredFilenameExtension : fileURL.pathExtension
        return ext.map { "\(suggested).\($0)" } ?? suggested
    }

    private final class ResultsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<ImportedFile, Error>?]

        init(count: Int) { storage = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ result: Result<ImportedFile, Error>) {
            lock.lock()
            storage[index] = result
            lock.unlock()
        }

        var results: [Result<ImportedFile, Error>] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map { $0 ?? .failure(ImportError.noFile("Item")) }
        }
    }
}
