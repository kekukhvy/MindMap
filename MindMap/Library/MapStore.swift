import Foundation
import Observation

/// Where new maps go (WP14 setting).
enum StorageMode: String, CaseIterable, Codable {
    /// iCloud map library (CloudKit, no iCloud Drive needed).
    case library
    /// `.mindmap` files (local folder or iCloud Drive).
    case files
}

/// A map in a store.
enum MapLocation: Hashable {
    case file(URL)
    case library(UUID)
}

struct MapSummary: Identifiable, Hashable {
    var location: MapLocation
    var title: String
    var modified: Date?
    var isLocked: Bool

    var id: MapLocation { location }
}

/// Storage of maps. Both stores hand the editor an ordinary `.mindmap`
/// package URL (`packageURL(for:)`): the documents, the editor and every
/// feature work on that package and do not know which store it belongs to.
@MainActor
protocol MapStore: AnyObject {
    var mode: StorageMode { get }
    func maps() -> [MapSummary]
    /// A new, empty map whose central topic is `title`.
    func createMap(titled title: String) throws -> MapSummary
    /// The package the editor opens (nil = not available any more).
    func packageURL(for location: MapLocation) -> URL?
    func deleteMap(_ location: MapLocation) throws
}

/// `.mindmap` files in one folder (the existing documents).
final class FileMapStore: MapStore {
    let folder: URL
    let mode = StorageMode.files

    init(folder: URL) {
        self.folder = folder
    }

    func maps() -> [MapSummary] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [
            .contentModificationDateKey,
        ])) ?? []
        return urls.filter { $0.pathExtension == MapPaths.fileExtension }.map { url in
            let isLocked = FileManager.default.fileExists(atPath: url.appendingPathComponent(LockHeader.fileName).path)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return MapSummary(location: .file(url), title: MapPaths.displayName(of: url), modified: modified,
                              isLocked: isLocked)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func createMap(titled title: String) throws -> MapSummary {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let name = UntitledName.next(existing: names, pathExtension: MapPaths.fileExtension,
                                     base: MapPaths.fileNameBase(forTopic: title))
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try MapFiles.newMapPackage(named: title).write(to: url, options: .atomic, originalContentsURL: nil)
        return MapSummary(location: .file(url), title: MapPaths.displayName(of: url), modified: Date(), isLocked: false)
    }

    func packageURL(for location: MapLocation) -> URL? {
        guard case let .file(url) = location, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func deleteMap(_ location: MapLocation) throws {
        guard case let .file(url) = location else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// The iCloud map library: cached packages (`LibraryCache`) synced by
/// `LibrarySync` (works offline; uploads when the account is available).
@MainActor
final class LibraryMapStore: MapStore {
    let mode = StorageMode.library
    let sync: LibrarySync
    var cache: LibraryCache { sync.cache }

    init(sync: LibrarySync) {
        self.sync = sync
    }

    func maps() -> [MapSummary] {
        cache.mapIDs().map { id in
            let meta = sync.state.maps[id]
            var title = meta?.title
            var isLocked = meta?.isEncrypted ?? false
            var modified = meta?.modified
            if meta == nil, let url = cache.packageURL(for: id),
               let snapshot = try? LibraryPackageSnapshot.read(at: url, mapID: id) {
                title = snapshot.title
                isLocked = snapshot.isEncrypted
                modified = snapshot.modified
            }
            // Locked maps carry no plaintext title: their package name here.
            let packageName = cache.packageURL(for: id).map(MapPaths.displayName(of:))
            return MapSummary(location: .library(id), title: title ?? packageName ?? LibraryTitle.lockedMap,
                              modified: modified, isLocked: isLocked)
        }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    func createMap(titled title: String) throws -> MapSummary {
        try importMap(MindMap(root: Node(text: LinkCandidate.displayText(title))))
    }

    /// Adds `map` (+ attachment files by name) as a new library map.
    func importMap(_ map: MindMap, attachments: [String: URL] = [:]) throws -> MapSummary {
        let id = UUID()
        let wrapper = try LibrarySync.package(payload: try MindMapPackage.encode(map), lockHeader: nil, files: attachments)
        try cache.writePackage(wrapper, for: id, title: LibraryTitle.title(of: map))
        sync.checkForLocalChanges(id)
        return MapSummary(location: .library(id), title: LibraryTitle.title(of: map), modified: Date(), isLocked: false)
    }

    func packageURL(for location: MapLocation) -> URL? {
        guard case let .library(id) = location else { return nil }
        return cache.packageURL(for: id)
    }

    func deleteMap(_ location: MapLocation) throws {
        guard case let .library(id) = location else { return }
        sync.deleteMap(id)
    }
}

/// The storage setting (WP14): explicit choice persisted in UserDefaults;
/// without one, the library when iCloud is available, else files.
@MainActor
@Observable
final class StorageSettings {
    static let key = "MindMap.storageMode"

    @ObservationIgnored private let defaults: UserDefaults
    private var stored: StorageMode?
    /// Set from `LibraryService` once the account was checked.
    var isLibraryAvailable = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.string(forKey: Self.key).flatMap(StorageMode.init(rawValue:))
    }

    var storageMode: StorageMode {
        get { stored ?? (isLibraryAvailable ? .library : .files) }
        set {
            stored = newValue
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }

    /// The user picked a mode (vs. the availability default).
    var hasExplicitChoice: Bool { stored != nil }
}
