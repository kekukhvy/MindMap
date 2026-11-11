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

    /// Builds the package. Reuses the existing `attachments/` folder and any
    /// other entries of the saved package (e.g. written by a newer version)
    /// as-is, so unchanged files are not rewritten (cheap in iCloud Drive).
    /// Only relative names are stored; nothing references absolute paths.
    static func fileWrapper(for map: MindMap, existing: FileWrapper? = nil) throws -> FileWrapper {
        let mapWrapper = FileWrapper(regularFileWithContents: try encode(map))
        mapWrapper.preferredFilename = mapFileName

        var children: [String: FileWrapper] = [:]
        if existing?.isDirectory == true {
            for (name, child) in existing?.fileWrappers ?? [:] where name != mapFileName {
                children[name] = child
            }
        }
        if children[attachmentsFolderName]?.isDirectory != true {
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

    static func encode(_ map: MindMap) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(map)
    }

    static func decode(_ data: Data) throws -> MindMap {
        try JSONDecoder().decode(MindMap.self, from: data)
    }
}
