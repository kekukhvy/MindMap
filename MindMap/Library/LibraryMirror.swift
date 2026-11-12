import Foundation
import Observation

/// "Mirror library to folder" settings (WP14b), UserDefaults-backed.
@MainActor
@Observable
final class LibraryMirrorSettings {
    static let enabledKey = "MindMap.mirror.enabled"
    static let bookmarkKey = "MindMap.mirror.folderBookmark"
    static let copiesKey = "MindMap.mirror.includeMapCopies"

    @ObservationIgnored private let defaults: UserDefaults

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Self.enabledKey) } }
    /// Security-scoped bookmark of the chosen folder.
    var folderBookmark: Data? { didSet { defaults.set(folderBookmark, forKey: Self.bookmarkKey) } }
    /// Also write `.mindmap` copies next to the notes.
    var includesMapCopies: Bool { didSet { defaults.set(includesMapCopies, forKey: Self.copiesKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        folderBookmark = defaults.data(forKey: Self.bookmarkKey)
        includesMapCopies = defaults.bool(forKey: Self.copiesKey)
    }

    /// The chosen folder (resolved bookmark; nil = none / gone).
    var folderURL: URL? {
        guard let folderBookmark else { return nil }
        return try? FolderBookmark.resolve(folderBookmark)
    }

    func setFolder(_ url: URL) throws {
        folderBookmark = try FolderBookmark.make(url)
    }
}

/// Security-scoped folder bookmarks (macOS sandbox: app scope; iOS: a
/// plain bookmark of the picked folder, accessed with its security scope).
enum FolderBookmark {
    static func make(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    static func resolve(_ data: Data) throws -> URL {
        var stale = false
        #if os(macOS)
        return try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                       bookmarkDataIsStale: &stale)
        #else
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
    }
}

/// Keeps the mirror folder up to date (one-way: library → folder) a few
/// seconds after library changes, while the setting is on.
@MainActor
@Observable
final class LibraryMirror {
    let settings: LibraryMirrorSettings
    @ObservationIgnored private let store: LibraryMapStore
    /// Result of the last run for Settings ("Mirrored 3 maps", error text).
    private(set) var lastResult: String?
    var delay: Duration = .seconds(2)
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(store: LibraryMapStore, settings: LibraryMirrorSettings) {
        self.store = store
        self.settings = settings
    }

    func scheduleUpdate() {
        guard settings.isEnabled, settings.folderBookmark != nil else { return }
        pending?.cancel()
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.updateNow()
        }
    }

    /// Writes the mirror now (Settings toggle / folder change).
    @discardableResult
    func updateNow() -> LibraryMirrorWriter.Report? {
        pending?.cancel()
        pending = nil
        guard settings.isEnabled else { return nil }
        guard let folder = settings.folderURL else {
            lastResult = "Choose a folder for the mirror."
            return nil
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let sources = store.maps().compactMap { summary -> LibraryMirrorWriter.Source? in
            guard let url = store.packageURL(for: summary.location) else { return nil }
            return .init(title: summary.title, packageURL: url, isLocked: summary.isLocked)
        }
        do {
            let report = try LibraryMirrorWriter.write(sources, to: folder,
                                                       includeMapCopies: settings.includesMapCopies)
            let time = Date().formatted(date: .omitted, time: .shortened)
            lastResult = "Mirrored \(sources.count) map\(sources.count == 1 ? "" : "s") at \(time)"
            return report
        } catch {
            lastResult = "The mirror could not be written: \(error.localizedDescription)"
            return nil
        }
    }
}

/// Writes the mirror folder: `<Title>.md` per plain map (locked maps get
/// none), optional `<Title>.mindmap` copies (locked ones stay encrypted).
/// Only files listed in its own manifest (`.mindmap-mirror.json`) are
/// ever replaced or removed — the user's other notes in the folder are
/// left alone. Unchanged files are not rewritten (no churn in Obsidian).
enum LibraryMirrorWriter {
    static let manifestName = ".mindmap-mirror.json"

    struct Source {
        var title: String
        var packageURL: URL
        var isLocked: Bool
    }

    struct Report: Equatable {
        var written: [String] = []
        var unchanged: [String] = []
        var removed: [String] = []
    }

    private struct Manifest: Codable {
        var files: [String] = []
        /// `.mindmap` copies: name -> signature of the source package.
        var copies: [String: String] = [:]
    }

    static func write(_ sources: [Source], to folder: URL, includeMapCopies: Bool) throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifestURL = folder.appendingPathComponent(manifestName)
        let old = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            ?? Manifest()
        var new = Manifest()
        var report = Report()
        var usedBases = Set<String>()
        let ownedBefore = Set(old.files)

        func freeBase(_ title: String) -> String {
            let base = MapPaths.fileNameBase(forTopic: title)
            var candidate = base
            var index = 2
            // Not a name of ours, not a user file (".md" or ".mindmap").
            while usedBases.contains(candidate.lowercased())
                || ["md", MapPaths.fileExtension].contains(where: { ext in
                    let name = candidate + "." + ext
                    return !ownedBefore.contains(name) && fm.fileExists(atPath: folder.appendingPathComponent(name).path)
                }) {
                candidate = "\(base) \(index)"
                index += 1
            }
            usedBases.insert(candidate.lowercased())
            return candidate
        }

        for source in sources.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            let base = freeBase(source.title)
            if !source.isLocked, let map = try? MapFiles.readMap(at: source.packageURL) {
                let name = base + ".md"
                let text = MarkdownExport.markdown(of: map, title: source.title) { attachment in
                    noteText(attachment, in: source.packageURL)
                }
                let target = folder.appendingPathComponent(name)
                if (try? String(contentsOf: target, encoding: .utf8)) == text {
                    report.unchanged.append(name)
                } else {
                    try text.write(to: target, atomically: true, encoding: .utf8)
                    report.written.append(name)
                }
                new.files.append(name)
            }
            if includeMapCopies {
                let name = base + "." + MapPaths.fileExtension
                let target = folder.appendingPathComponent(name, isDirectory: true)
                let signature = packageSignature(source.packageURL)
                if old.copies[name] == signature, fm.fileExists(atPath: target.path) {
                    report.unchanged.append(name)
                } else {
                    try MapPackageIO.write(try MapPackageIO.read(source.packageURL), to: target)
                    report.written.append(name)
                }
                new.files.append(name)
                new.copies[name] = signature
            }
        }
        for name in old.files where !new.files.contains(name) {
            let url = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                report.removed.append(name)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(new).write(to: manifestURL, options: .atomic)
        return report
    }

    /// Plain Markdown note text; nil for locked notes (never decrypted here).
    static func noteText(_ attachment: Attachment, in packageURL: URL) -> String? {
        guard attachment.kind == .markdown, !attachment.isLocked,
              !attachment.fileName.hasSuffix(".enc") else { return nil }
        let url = packageURL.appendingPathComponent(MindMapPackage.attachmentsFolderName)
            .appendingPathComponent(attachment.fileName)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Changes whenever a file of the package changes (names, sizes, dates).
    static func packageSignature(_ url: URL) -> String {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return "" }
        var parts: [String] = []
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            parts.append("\(file.lastPathComponent):\(values?.fileSize ?? -1):"
                + "\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)")
        }
        return LibraryHash.sha256(Data(parts.sorted().joined(separator: "|").utf8))
    }
}
