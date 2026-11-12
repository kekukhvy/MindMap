import Foundation
import Observation

/// Bookmarks stored in map links. macOS (sandbox): security-scoped, so a
/// map the user once picked can be opened again without asking; falls back
/// to a plain bookmark. iOS: a bookmark of a picked (security-scoped) URL
/// carries its scope implicitly.
struct MapBookmarkCoder: BookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            return data
        }
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        #if os(macOS)
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        #endif
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

/// Finds the file of a map link: relative path from the linking document's
/// folder → bookmark (refreshed when stale or when the relative path no
/// longer matches) → missing.
struct MapLinkResolver {
    enum Resolution: Equatable {
        /// `refreshed`: the reference with an updated path / bookmark / name
        /// to store (nil = unchanged).
        case found(URL, refreshed: MapReference?)
        case missing
    }

    var coder: BookmarkCoding = MapBookmarkCoder()
    var exists: (URL) -> Bool = LastDocumentStore.itemExists

    func resolve(_ reference: MapReference, documentURL: URL?) -> Resolution {
        let bookmarked = reference.bookmark.flatMap { try? coder.resolve($0) }
        if let documentURL, let path = reference.relativePath,
           let candidate = MapPaths.resolve(path, from: documentURL), exists(candidate) {
            // Same file as the bookmark: open through the bookmark's URL
            // (carries the security scope on macOS).
            if let bookmarked, LaunchEnvironment.key(bookmarked.url) == LaunchEnvironment.key(candidate) {
                var updated = reference
                if bookmarked.isStale, let data = try? coder.bookmark(for: bookmarked.url) { updated.bookmark = data }
                return .found(bookmarked.url, refreshed: updated == reference ? nil : updated)
            }
            return .found(candidate, refreshed: nil)
        }
        if let bookmarked, exists(bookmarked.url) {
            var updated = reference
            if bookmarked.isStale, let data = try? coder.bookmark(for: bookmarked.url) { updated.bookmark = data }
            if let documentURL, let path = MapPaths.relativePath(from: documentURL, to: bookmarked.url) {
                updated.relativePath = path
            }
            updated.displayName = MapPaths.displayName(of: bookmarked.url)
            return .found(bookmarked.url, refreshed: updated == reference ? nil : updated)
        }
        return .missing
    }

    /// Reference to `url` from a document at `documentURL` (nil = never
    /// saved: bookmark only; the relative path is added once it is saved).
    func reference(to url: URL, from documentURL: URL?, targetTopicID: UUID? = nil) -> MapReference {
        MapReference(relativePath: documentURL.flatMap { MapPaths.relativePath(from: $0, to: url) },
                     bookmark: try? coder.bookmark(for: url),
                     displayName: MapPaths.displayName(of: url),
                     targetTopicID: targetTopicID)
    }

    /// Updates for links whose stored relative path is missing or wrong for
    /// `documentURL` (document saved for the first time, moved, Save As):
    /// resolved through the bookmark.
    func relativePathUpdates(for links: [(id: UUID, reference: MapReference)], documentURL: URL) -> [UUID: MapReference] {
        var updates: [UUID: MapReference] = [:]
        for (id, reference) in links {
            if let path = reference.relativePath, let candidate = MapPaths.resolve(path, from: documentURL),
               exists(candidate) {
                continue
            }
            if case let .found(_, refreshed?) = resolve(reference, documentURL: documentURL) { updates[id] = refreshed }
        }
        return updates
    }
}

/// Files of other maps: topic list for "Open at topic", "New Map…".
enum MapFiles {
    /// Topics of the map at `url` (read from its `map.json`).
    static func topics(at url: URL) throws -> [LinkCandidate] {
        try readMap(at: url).linkCandidates()
    }

    static func readMap(at url: URL) throws -> MindMap {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<MindMap, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result {
                let data = try Data(contentsOf: readURL.appendingPathComponent(MindMapPackage.mapFileName))
                return try MindMapPackage.decode(data)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// A new, empty map package (central topic = `name`) next to
    /// `documentURL`, named after the topic ("Name.mindmap", "Name 2.mindmap"
    /// if taken). Throws when the folder is not writable (sandbox: then the
    /// user picks the place in a save panel instead).
    static func createMap(named topicText: String, nextTo documentURL: URL) throws -> URL {
        let folder = MapPaths.baseFolder(of: documentURL)
        let base = MapPaths.fileNameBase(forTopic: topicText)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let fileName = UntitledName.next(existing: names, pathExtension: MapPaths.fileExtension, base: base)
        let url = folder.appendingPathComponent(fileName, isDirectory: true)
        try write(newMapPackage(named: topicText), to: url)
        return url
    }

    /// The package of a new map whose central topic is `topicText`.
    static func newMapPackage(named topicText: String) throws -> FileWrapper {
        let text = LinkCandidate.displayText(topicText)
        return try MindMapPackage.fileWrapper(for: MindMap(root: Node(text: text)))
    }

    private static func write(_ wrapper: FileWrapper, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do { try wrapper.write(to: target, options: .atomic, originalContentsURL: nil) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}

/// "Open at topic": a topic to select & reveal once a map's editor shows
/// (the map may be opening in another window/tab or already open there).
/// Keyed by `LaunchEnvironment.key` of the document URL.
@MainActor
@Observable
final class MapRevealCenter {
    static let shared = MapRevealCenter()

    private(set) var requests: [String: MapRevealRequest] = [:]

    func request(_ topicID: UUID, in documentURL: URL) {
        requests[LaunchEnvironment.key(documentURL)] = MapRevealRequest(topicID: topicID)
    }

    func pending(for documentURL: URL?) -> MapRevealRequest? {
        documentURL.flatMap { requests[LaunchEnvironment.key($0)] }
    }

    /// Takes the request (the editor of that document handles it once).
    func take(for documentURL: URL) -> UUID? {
        let key = LaunchEnvironment.key(documentURL)
        defer { requests[key] = nil }
        return requests[key]?.topicID
    }
}

struct MapRevealRequest: Equatable {
    let id = UUID()
    var topicID: UUID
}

/// Security scopes of map files opened through links stay open while the
/// app runs (the opened document reads and saves through them).
enum MapFileAccess {
    nonisolated(unsafe) private static var open: Set<String> = []

    static func retain(_ url: URL) {
        let key = LaunchEnvironment.key(url)
        guard !open.contains(key), url.startAccessingSecurityScopedResource() else { return }
        open.insert(key)
    }
}
