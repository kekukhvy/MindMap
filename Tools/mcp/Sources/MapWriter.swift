import Foundation

/// A markdown file to store in `attachments/` together with a map write.
struct NoteFile {
    let name: String
    let data: Data
}

/// Writes a changed map: stale check, backups outside the package, atomic writes.
struct MapWriter {
    static let backupsEnvironmentKey = "MINDMAP_MCP_BACKUPS"
    /// Backups kept per map (and per kind: map.json, note files).
    static let backupsKept = 20
    static let mapBackupSuffix = "-map.json"
    static let noteBackupInfix = "-note-"
    private static let timestampFormat = "yyyyMMdd-HHmmss-SSS"

    let library: MapLibrary
    let backupsRoot: URL

    init(library: MapLibrary, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.library = library
        if let path = environment[MapWriter.backupsEnvironmentKey], !path.isEmpty {
            backupsRoot = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            backupsRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/mindmap-mcp/backups", isDirectory: true)
        }
    }

    func commit(_ original: LoadedMap, _ map: MindMap, note: NoteFile? = nil) throws {
        let entry = original.entry
        guard MapLibrary.modificationDate(entry.mapFileURL) == original.modified else {
            throw ToolError("Map '\(entry.packageName)' changed while editing. Read it again (read_map), then repeat.")
        }
        let newData = try MindMapPackage.encode(map)
        let backupFolder = backupsRoot.appendingPathComponent(entry.id, isDirectory: true)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let stamp = Self.timestamp()
        try original.data.write(to: backupFolder.appendingPathComponent(stamp + Self.mapBackupSuffix))
        try prune(backupFolder, containing: Self.mapBackupSuffix)
        if let note { try writeNote(note, entry: entry, backupFolder: backupFolder, stamp: stamp) }
        try newData.write(to: entry.mapFileURL, options: .atomic)
        library.rememberWritten(entry)
    }

    private func writeNote(_ note: NoteFile, entry: MapEntry, backupFolder: URL, stamp: String) throws {
        let folder = entry.packageURL.appendingPathComponent(MindMapPackage.attachmentsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(note.name)
        if let old = try? Data(contentsOf: target) {
            try old.write(to: backupFolder.appendingPathComponent(stamp + Self.noteBackupInfix + note.name))
            try prune(backupFolder, containing: Self.noteBackupInfix)
        }
        try note.data.write(to: target, options: .atomic)
    }

    /// Keeps the newest `backupsKept` files whose name contains `marker`.
    private func prune(_ folder: URL, containing marker: String) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains(marker) }.sorted()
        for name in names.dropLast(Self.backupsKept) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timestampFormat
        return formatter.string(from: Date())
    }
}
