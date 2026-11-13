import Foundation

/// One entry of Welcome ▸ Recent Files.
struct RecentMap: Identifiable, Equatable {
    var url: URL
    var lastOpened: Date?
    var id: String { LaunchEnvironment.key(url) }
    var name: String { MapPaths.displayName(of: url) }
}

/// Bookmarks of security-scoped files: on macOS (sandbox) an app-scoped
/// security bookmark, so a recent file outside the container reopens after
/// a relaunch; on iOS a plain bookmark (carries the document's scope).
struct ScopedBookmarkCoder: BookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        try FolderBookmark.make(url)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return (url, stale)
    }
}

/// The app's own list of recently opened `.mindmap` files (WP13 Welcome):
/// UserDefaults, most recent first, at most `limit`, bookmark + path per
/// file. macOS adds NSDocumentController's recents (`merged(with:)`).
/// Files that are gone are pruned when the list is read; "Remove from
/// List" also hides the file from the system recents.
struct RecentMapsStore {
    let defaults: UserDefaults
    var key = "MindMap.recentMaps"
    var hiddenKey = "MindMap.recentMaps.hidden"
    var limit = 10
    var coder: BookmarkCoding = ScopedBookmarkCoder()
    var exists: (URL) -> Bool = LastDocumentStore.itemExists

    /// The store of the app (separate suite in the unit-test host).
    @MainActor static var shared: RecentMapsStore { RecentMapsStore(defaults: LibraryService.defaults) }

    private struct Entry: Codable {
        var path: String
        var bookmark: Data?
        var date: Date
    }

    private func load() -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func save(_ entries: [Entry]) {
        defaults.set(try? JSONEncoder().encode(Array(entries.prefix(limit))), forKey: key)
    }

    private var hidden: Set<String> {
        Set(defaults.stringArray(forKey: hiddenKey) ?? [])
    }

    /// `url` was opened (moves it to the top).
    func note(_ url: URL, date: Date = Date()) {
        let id = LaunchEnvironment.key(url)
        var entries = load().filter { $0.path != id }
        entries.insert(Entry(path: id, bookmark: try? coder.bookmark(for: url), date: date), at: 0)
        save(entries)
        if hidden.contains(id) { defaults.set(Array(hidden.subtracting([id])), forKey: hiddenKey) }
    }

    /// "Remove from List".
    func remove(_ url: URL) {
        let id = LaunchEnvironment.key(url)
        save(load().filter { $0.path != id })
        defaults.set(Array(hidden.union([id])).sorted(), forKey: hiddenKey)
    }

    /// The remembered files that still exist, most recent first (stale
    /// bookmarks refreshed, missing files dropped from the store).
    func entries() -> [RecentMap] {
        var kept: [Entry] = []
        var result: [RecentMap] = []
        var changed = false
        for var entry in load() {
            var url: URL?
            if let data = entry.bookmark, let resolved = try? coder.resolve(data), exists(resolved.url) {
                url = resolved.url
                if resolved.isStale || LaunchEnvironment.key(resolved.url) != entry.path {
                    entry.bookmark = try? coder.bookmark(for: resolved.url)
                    entry.path = LaunchEnvironment.key(resolved.url)
                    changed = true
                }
            } else if exists(URL(fileURLWithPath: entry.path)) {
                url = URL(fileURLWithPath: entry.path)
            }
            guard let url, !result.contains(where: { $0.id == LaunchEnvironment.key(url) }) else {
                changed = true
                continue
            }
            kept.append(entry)
            result.append(RecentMap(url: url, lastOpened: entry.date))
        }
        if changed { save(kept) }
        return Array(result.prefix(limit))
    }

    /// Own entries first (by date), then `system` recents (most recent
    /// first, e.g. NSDocumentController) that are not listed, not removed
    /// and still exist; `excluding` drops e.g. library packages.
    func merged(with system: [URL], excluding: (URL) -> Bool = { _ in false }) -> [RecentMap] {
        var result = entries().filter { !excluding($0.url) }
        let hidden = hidden
        for url in system {
            let id = LaunchEnvironment.key(url)
            guard !hidden.contains(id), !result.contains(where: { $0.id == id }), !excluding(url), exists(url) else {
                continue
            }
            result.append(RecentMap(url: url, lastOpened: nil))
        }
        return Array(result.prefix(limit))
    }

    func removeAll() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: hiddenKey)
    }
}
