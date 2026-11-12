import Foundation

/// A link to another `.mindmap` file (WP10). Found by its path relative to
/// the linking document's folder first (works for a folder of maps synced
/// via iCloud Drive / copied to another device), then by bookmark (this
/// device; file moved or renamed; security scope on macOS).
/// JSON (inside a link): `"path"`, `"bookmark"` (base64), `"name"`,
/// `"topicID"`.
struct MapReference: Equatable, Hashable {
    /// "Other.mindmap", "Projects/Plan.mindmap", "../Shared/Ideas.mindmap";
    /// nil while the linking document was never saved.
    var relativePath: String?
    var bookmark: Data?
    /// File name without extension (menus, tooltip, missing-file messages).
    var displayName: String
    /// Topic to select and reveal when the map opens.
    var targetTopicID: UUID?

    init(relativePath: String?, bookmark: Data? = nil, displayName: String? = nil, targetTopicID: UUID? = nil) {
        self.relativePath = relativePath
        self.bookmark = bookmark
        self.displayName = displayName ?? relativePath.map(MapPaths.displayName(ofPath:)) ?? "Map"
        self.targetTopicID = targetTopicID
    }

    /// Something to find the file with.
    var isUsable: Bool { relativePath?.isEmpty == false || bookmark != nil }

    /// "Plan.mindmap" / "Projects/Plan.mindmap" for tooltips; the name when
    /// only a bookmark is known.
    var pathDescription: String { relativePath ?? displayName + "." + MapPaths.fileExtension }
}

/// Pure path helpers for map links.
enum MapPaths {
    static let fileExtension = "mindmap"

    /// Folder the relative paths start from: the document's parent folder.
    static func baseFolder(of documentURL: URL) -> URL {
        documentURL.standardizedFileURL.deletingLastPathComponent()
    }

    /// Path of `target` relative to `documentURL`'s folder ("x.mindmap",
    /// "sub/x.mindmap", "../other/x.mindmap"). Symlinks are resolved on both
    /// sides (/var vs /private/var). nil if not both file URLs.
    static func relativePath(from documentURL: URL, to target: URL) -> String? {
        guard documentURL.isFileURL, target.isFileURL else { return nil }
        let base = components(of: baseFolder(of: documentURL))
        let destination = components(of: target.standardizedFileURL)
        guard !destination.isEmpty else { return nil }
        var common = 0
        while common < base.count, common < destination.count - 1, base[common] == destination[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + destination[common...]).joined(separator: "/")
    }

    /// URL of `relativePath` from `documentURL`'s folder (nil for an
    /// absolute or empty path).
    static func resolve(_ relativePath: String, from documentURL: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        var url = baseFolder(of: documentURL)
        for part in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": url = url.deletingLastPathComponent()
            default: url = url.appendingPathComponent(String(part))
            }
        }
        return url.standardizedFileURL
    }

    static func displayName(ofPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Safe file name base for a new map named after a topic ("A/B: c" ->
    /// "A-B- c"; empty -> "Untitled"; at most 80 characters).
    static func fileNameBase(forTopic text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var name = line.map { "/:\\".contains($0) ? "-" : String($0) }.joined()
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? UntitledName.base : name
    }

    private static func components(of url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.filter { $0 != "/" }
    }
}
