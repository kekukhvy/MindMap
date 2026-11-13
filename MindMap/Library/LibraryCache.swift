import Foundation

/// The library's offline-first local cache (WP14). Every library map is an
/// ordinary `.mindmap` package, so the existing documents (macOS
/// `MindMapDocument`, iPad `MindMapUIDocument`), attachments, locks and map
/// links read and write it unchanged:
///
///     <root>/Maps/<map UUID>/<Title>.mindmap     the package the editor opens
///     <root>/Sync/state.json                     per-map sync bookkeeping
///     <root>/Sync/engine-state.json              CKSyncEngine state
///     <root>/Sync/base/<map UUID>.json           last synced map.json (merge base)
///     <root>/Sync/outbox/                        staged upload copies (CKAssets)
///     <root>/Sync/incoming/<map UUID>/           fetched payload + attachments
///                                                waiting to be integrated
///
/// `root` = Application Support/MindMap/Library (sandbox container on
/// macOS; not visible in Files on iPad); a temporary folder in tests.
/// File operations only — thread-safe, no actor.
final class LibraryCache: @unchecked Sendable {
    /// App-wide cache (Application Support, or a per-process temporary
    /// folder in the unit-test host).
    static let shared: LibraryCache = {
        if LaunchEnvironment.isTesting {
            return LibraryCache(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("MindMapTestLibrary-\(ProcessInfo.processInfo.processIdentifier)"))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibraryCache(root: support.appendingPathComponent("MindMap/Library", isDirectory: true))
    }()

    let root: URL
    private let lock = NSLock()

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    var mapsFolder: URL { root.appendingPathComponent("Maps", isDirectory: true) }
    var syncFolder: URL { root.appendingPathComponent("Sync", isDirectory: true) }
    var outboxFolder: URL { syncFolder.appendingPathComponent("outbox", isDirectory: true) }

    var incomingRoot: URL { syncFolder.appendingPathComponent("incoming", isDirectory: true) }

    func incomingFolder(for id: UUID) -> URL {
        incomingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Maps with fetched files waiting in `incoming/`.
    func incomingMapIDs() -> [UUID] {
        ((try? FileManager.default.contentsOfDirectory(atPath: incomingRoot.path)) ?? []).compactMap(UUID.init(uuidString:))
    }

    // MARK: Maps

    /// IDs of all maps in the cache.
    func mapIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mapsFolder.path)) ?? []
        return names.compactMap(UUID.init(uuidString:)).filter { packageURL(for: $0) != nil }
    }

    /// The package of map `id` (nil = not in the cache).
    func packageURL(for id: UUID) -> URL? {
        let folder = mapsFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let name = names.sorted().first(where: { $0.hasSuffix("." + MapPaths.fileExtension) }) else { return nil }
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    /// The library map whose package is (or contains) `url`.
    func mapID(containing url: URL) -> UUID? {
        let maps = LaunchEnvironment.key(mapsFolder) + "/"
        let path = LaunchEnvironment.key(url)
        guard path.hasPrefix(maps) else { return nil }
        let rest = path.dropFirst(maps.count)
        return rest.split(separator: "/").first.flatMap { UUID(uuidString: String($0)) }
    }

    /// Where a new package of map `id` named `title` goes.
    func newPackageURL(for id: UUID, title: String) -> URL {
        mapsFolder.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(MapPaths.fileNameBase(forTopic: title) + "." + MapPaths.fileExtension,
                                    isDirectory: true)
    }

    /// Writes `wrapper` as the package of map `id` (replacing the current
    /// one through file coordination, so an open document notices and
    /// reverts). The package keeps its file name; new maps are named after
    /// `title`.
    @discardableResult
    func writePackage(_ wrapper: FileWrapper, for id: UUID, title: String) throws -> URL {
        let url = packageURL(for: id) ?? newPackageURL(for: id, title: title)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".writing-\(UUID().uuidString)")
        try wrapper.write(to: temporary, options: [], originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
        return url
    }

    /// Removes map `id` (package folder + base snapshot + incoming files).
    func removeMap(_ id: UUID) {
        let folder = mapsFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        if let url = packageURL(for: id) {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) {
                try? FileManager.default.removeItem(at: $0)
            }
        }
        try? FileManager.default.removeItem(at: folder)
        setBase(nil, for: id)
        try? FileManager.default.removeItem(at: incomingFolder(for: id))
    }

    // MARK: Merge base

    private func baseURL(for id: UUID) -> URL {
        syncFolder.appendingPathComponent("base/\(id.uuidString).json")
    }

    /// The last synced plain `map.json` of map `id` (three-way merge base).
    func base(for id: UUID) -> MindMap? {
        (try? Data(contentsOf: baseURL(for: id))).flatMap { try? MindMapPackage.decode($0) }
    }

    func setBase(_ data: Data?, for id: UUID) {
        let url = baseURL(for: id)
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Staging

    /// A copy of `source` (clone on APFS) in the outbox: CloudKit uploads
    /// from it while the package may already be saved again.
    func stageUpload(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: outboxFolder, withIntermediateDirectories: true)
        let target = outboxFolder.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    func stageUpload(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outboxFolder, withIntermediateDirectories: true)
        let target = outboxFolder.appendingPathComponent(UUID().uuidString + "-" + name)
        try data.write(to: target)
        return target
    }

    func removeStaged(_ url: URL?) {
        guard let url, LaunchEnvironment.key(url).hasPrefix(LaunchEnvironment.key(outboxFolder)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: State files

    var stateURL: URL { syncFolder.appendingPathComponent("state.json") }
    var engineStateURL: URL { syncFolder.appendingPathComponent("engine-state.json") }

    func loadState() -> LibrarySyncState {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(LibrarySyncState.self, from: data) else { return LibrarySyncState() }
        return state
    }

    func saveState(_ state: LibrarySyncState) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try? encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    func loadEngineState() -> Data? {
        try? Data(contentsOf: engineStateURL)
    }

    func saveEngineState(_ data: Data?) {
        try? FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        if let data {
            try? data.write(to: engineStateURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: engineStateURL)
        }
    }
}

/// Sync bookkeeping of the whole library (`Sync/state.json`).
struct LibrarySyncState: Codable, Equatable {
    var maps: [UUID: MapSyncMeta] = [:]
    /// Deleted here, deletion not confirmed by the server yet.
    var deletedMaps: Set<UUID> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maps = try c.decodeIfPresent([UUID: MapSyncMeta].self, forKey: .maps) ?? [:]
        deletedMaps = try c.decodeIfPresent(Set<UUID>.self, forKey: .deletedMaps) ?? []
    }
}

/// What the server has of one map, as far as this device knows.
struct MapSyncMeta: Codable, Equatable {
    /// Archived system fields of the last known Map record (change tag).
    var systemFields: Data?
    var revision = 0
    /// `payloadHash` the server has = the package content at the base.
    var syncedPayloadHash: String?
    /// Attachments the server has: name -> SHA-256.
    var syncedAttachments: [String: String] = [:]
    var attachmentSystemFields: [String: Data] = [:]
    /// Referenced by the server's map but not downloaded yet.
    var missingAttachments: Set<String> = []
    /// For listings without reading the package.
    var title: String?
    var isEncrypted = false
    var modified: Date?

    var isOnServer: Bool { systemFields != nil }
}
