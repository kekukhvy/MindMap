import Foundation

/// Reads/writes the `.mindmap` package: a directory FileWrapper with
/// `map.json` (the tree) and an `attachments/` folder (UUID-named files).
enum MindMapPackage {
    static let mapFileName = "map.json"
    static let attachmentsFolderName = "attachments"

    enum PackageError: Error {
        case notADirectory
        case missingMap
    }

    static func read(_ wrapper: FileWrapper) throws -> MindMap {
        guard wrapper.isDirectory else { throw PackageError.notADirectory }
        guard let data = wrapper.fileWrappers?[mapFileName]?.regularFileContents else {
            throw PackageError.missingMap
        }
        return try decode(data)
    }

    /// Builds the package. Reuses any other entries of the saved package
    /// (e.g. written by a newer version) as-is, so unchanged files are not
    /// rewritten (cheap in iCloud Drive). Only relative names are stored.
    /// - Parameter attachments: children of `attachments/` (from
    ///   `AttachmentStore.prepareSave`); nil keeps the existing folder as-is.
    static func fileWrapper(for map: MindMap, existing: FileWrapper? = nil,
                            attachments: [String: FileWrapper]? = nil) throws -> FileWrapper {
        let mapWrapper = FileWrapper(regularFileWithContents: try encode(map))
        mapWrapper.preferredFilename = mapFileName

        var children: [String: FileWrapper] = [:]
        if existing?.isDirectory == true {
            // A plain save after "Remove Map Lock" drops the lock entries.
            for (name, child) in existing?.fileWrappers ?? [:]
            where name != mapFileName && !LockedPackage.lockEntryNames.contains(name) {
                children[name] = child
            }
        }
        if let attachments {
            // New folder wrapper; the file wrappers inside may be reused ones.
            let folder = FileWrapper(directoryWithFileWrappers: attachments)
            folder.preferredFilename = attachmentsFolderName
            children[attachmentsFolderName] = folder
        } else if children[attachmentsFolderName]?.isDirectory != true {
            let folder = FileWrapper(directoryWithFileWrappers: [:])
            folder.preferredFilename = attachmentsFolderName
            children[attachmentsFolderName] = folder
        }
        // Reused wrappers keep their names: setting `preferredFilename` on a
        // wrapper that still belongs to the old package throws
        // (NSGenericException "mutated while being enumerated").
        children[mapFileName] = mapWrapper
        return FileWrapper(directoryWithFileWrappers: children)
    }

    /// Package for a save of `map` with the store's pending/unchanged files.
    static func fileWrapper(for map: MindMap, store: AttachmentStore, existing: FileWrapper?) throws -> FileWrapper {
        try fileWrapper(for: map, existing: existing,
                        attachments: store.prepareSave(referencing: map.referencedAttachmentFileNames))
    }

    static func encode(_ map: MindMap) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(map)
    }

    static func decode(_ data: Data) throws -> MindMap {
        try JSONDecoder().decode(MindMap.self, from: data)
    }
}
