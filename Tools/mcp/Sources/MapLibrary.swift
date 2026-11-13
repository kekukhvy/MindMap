import Foundation

/// One `.mindmap` package found in the maps folder.
struct MapEntry {
    /// Name of the folder that holds the package (the library's map id).
    let id: String
    let packageURL: URL

    var mapFileURL: URL { packageURL.appendingPathComponent(MindMapPackage.mapFileName) }
    var lockFileURL: URL { packageURL.appendingPathComponent(LockHeader.fileName) }
    var isLocked: Bool { FileManager.default.fileExists(atPath: lockFileURL.path) }
    var packageName: String { packageURL.deletingPathExtension().lastPathComponent }
}

/// A map read from disk, with what the write check needs.
struct LoadedMap {
    let entry: MapEntry
    let map: MindMap
    let data: Data
    let modified: Date
}

/// Finds, reads and resolves maps in the maps folder (env `MINDMAP_LIBRARY`).
final class MapLibrary {
    static let libraryEnvironmentKey = "MINDMAP_LIBRARY"
    static let packageExtension = "mindmap"
    private static let defaultRelativePath =
        "Library/Containers/com.kekukh.MindMap/Data/Library/Application Support/MindMap/Library/Maps"

    let root: URL
    /// map.json modification time seen by the last tool call, per map id.
    private var seen: [String: Date] = [:]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = environment[MapLibrary.libraryEnvironmentKey], !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(MapLibrary.defaultRelativePath, isDirectory: true)
        }
    }

    func entries() -> [MapEntry] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            let inside = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let package = inside.first(where: { $0.pathExtension == MapLibrary.packageExtension }) else { return nil }
            return MapEntry(id: folder.lastPathComponent, packageURL: package)
        }
    }

    /// The map named by `reference`: a map id, or an exact name.
    func resolve(_ reference: String) throws -> MapEntry {
        let all = entries()
        if let byID = all.first(where: { $0.id.caseInsensitiveCompare(reference) == .orderedSame }) { return byID }
        let byName = all.filter { name(of: $0)?.caseInsensitiveCompare(reference) == .orderedSame }
        switch byName.count {
        case 0: throw ToolError("No map '\(reference)'. Use list_maps for the ids.")
        case 1: return byName[0]
        default:
            let ids = byName.map(\.id).joined(separator: ", ")
            throw ToolError("Several maps are named '\(reference)'. Use one of these map ids: \(ids)")
        }
    }

    /// Name shown in lists: the map's title, else its central topic; the package name when locked.
    func name(of entry: MapEntry) -> String? {
        guard !entry.isLocked, let map = try? readPlain(entry).map else { return entry.packageName }
        return map.title ?? map.root.text
    }

    /// Reads a map for reading. Refuses locked maps and newer formats.
    func load(_ entry: MapEntry) throws -> LoadedMap {
        let loaded = try readPlain(entry)
        seen[entry.id] = loaded.modified
        return loaded
    }

    /// Reads a map for writing: also refuses read-only maps.
    func loadForWrite(_ entry: MapEntry) throws -> LoadedMap {
        let loaded = try readPlain(entry)
        if loaded.map.isReadOnly { throw ToolError("Map '\(entry.packageName)' is read-only (Lock Editing is on).") }
        if let before = seen[entry.id], before != loaded.modified {
            throw ToolError("Map '\(entry.packageName)' changed since you read it. Read it again (read_map), then repeat.")
        }
        return loaded
    }

    func rememberWritten(_ entry: MapEntry) {
        seen[entry.id] = Self.modificationDate(entry.mapFileURL)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func readPlain(_ entry: MapEntry) throws -> LoadedMap {
        if entry.isLocked { throw ToolError("Map '\(entry.packageName)' is locked; it is skipped.") }
        guard let modified = Self.modificationDate(entry.mapFileURL),
              let data = try? Data(contentsOf: entry.mapFileURL) else {
            throw ToolError("Map '\(entry.packageName)' has no readable map.json.")
        }
        let map: MindMap
        do { map = try MindMapPackage.decode(data) } catch {
            throw ToolError("Map '\(entry.packageName)' cannot be decoded: \(error.localizedDescription)")
        }
        if map.formatVersion > MindMap.currentFormatVersion {
            throw ToolError("Map '\(entry.packageName)' has format version \(map.formatVersion); this server knows up to \(MindMap.currentFormatVersion). Update mindmap-mcp.")
        }
        return LoadedMap(entry: entry, map: map, data: data, modified: modified)
    }
}
