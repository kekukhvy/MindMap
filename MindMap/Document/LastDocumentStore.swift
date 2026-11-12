import Foundation

/// Turns a file URL into persistent bookmark data and back.
protocol BookmarkCoding {
    func bookmark(for url: URL) throws -> Data
    /// Resolved URL and whether the bookmark should be recreated.
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
}

/// System bookmarks. Used on iOS, where a bookmark of a security-scoped URL
/// (document picker, Files "open in place") carries its scope implicitly.
/// (macOS reopens documents via NSDocumentController's recent documents.)
struct SystemBookmarkCoder: BookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

/// Remembers the last opened document across launches (UserDefaults):
/// a bookmark plus, as fallback, its path relative to one of the app's own
/// document folders (local Documents / iCloud container), which survives
/// the container path changing after a reinstall or restore when the
/// bookmark no longer resolves.
struct LastDocumentStore {
    let defaults: UserDefaults
    var key = "MindMap.lastDocument"
    var coder: BookmarkCoding = SystemBookmarkCoder()
    /// Whether a resolved URL still points at a document.
    var exists: (URL) -> Bool = LastDocumentStore.itemExists

    private static let bookmarkKey = "bookmark"
    private static let relativePathKey = "relativePath"

    /// Stores `url`. `roots` = the app's own document folders.
    func remember(_ url: URL, roots: [URL]) {
        var entry: [String: Any] = [:]
        if let data = try? coder.bookmark(for: url) { entry[Self.bookmarkKey] = data }
        if let relative = Self.relativePath(of: url, in: roots) { entry[Self.relativePathKey] = relative }
        if entry.isEmpty { forget() } else { defaults.set(entry, forKey: key) }
    }

    func forget() {
        defaults.removeObject(forKey: key)
    }

    /// The remembered document if it is still there: bookmark first, then the
    /// relative path inside `roots`. Refreshes a stale entry; clears an
    /// unusable one (so the caller creates a new map).
    func resolve(roots: [URL]) -> URL? {
        guard let entry = defaults.dictionary(forKey: key) else { return nil }
        if let data = entry[Self.bookmarkKey] as? Data,
           let resolved = try? coder.resolve(data), exists(resolved.url) {
            if resolved.isStale { remember(resolved.url, roots: roots) }
            return resolved.url
        }
        if let relative = entry[Self.relativePathKey] as? String {
            for root in roots {
                let candidate = root.appendingPathComponent(relative)
                if exists(candidate) {
                    remember(candidate, roots: roots)
                    return candidate
                }
            }
        }
        forget()
        return nil
    }

    /// Path of `url` below the first root containing it (symlinks resolved,
    /// e.g. /var vs /private/var).
    static func relativePath(of url: URL, in roots: [URL]) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        for root in roots {
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if path.hasPrefix(prefix), path.count > prefix.count {
                return String(path.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// File exists (accessing the security scope if needed) or is an iCloud
    /// item that is not downloaded yet.
    static func itemExists(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: url.path) { return true }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true
    }
}
