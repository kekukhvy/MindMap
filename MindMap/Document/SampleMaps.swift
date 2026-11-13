import Foundation

/// One `.mindmap` package as a single resource file (WP13): the app ships
/// the two sample maps as `sample-features.json` / `sample-roadmap.json`
/// (a package is a folder, which a synchronized Xcode group would flatten
/// into the bundle). Written from the committed `Samples/` packages by
/// `Tools/samples/bundle.sh`.
struct SamplePackageArchive: Codable, Equatable {
    /// Package name without extension ("MindMap Features").
    var name: String
    /// Path inside the package ("map.json", "attachments/<UUID>.md") → bytes.
    var files: [String: Data]

    /// The package as a directory wrapper.
    func fileWrapper() -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            var folder = root
            let parts = path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                if let existing = folder.fileWrappers?[part], existing.isDirectory {
                    folder = existing
                } else {
                    let child = FileWrapper(directoryWithFileWrappers: [:])
                    child.preferredFilename = part
                    folder.addFileWrapper(child)
                    folder = child
                }
            }
            let file = FileWrapper(regularFileWithContents: data)
            file.preferredFilename = parts.last ?? path
            folder.addFileWrapper(file)
        }
        return root
    }

    /// Reads every regular file below the package folder `url`.
    static func make(from url: URL) throws -> SamplePackageArchive {
        var files: [String: Data] = [:]
        let base = url.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  item.lastPathComponent != ".DS_Store" else { continue }
            let path = item.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { continue }
            files[String(path.dropFirst(base.count))] = try Data(contentsOf: item)
        }
        guard files[MindMapPackage.mapFileName] != nil else { throw CocoaError(.fileReadCorruptFile) }
        return SamplePackageArchive(name: MapPaths.displayName(of: url), files: files)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> SamplePackageArchive {
        try JSONDecoder().decode(SamplePackageArchive.self, from: data)
    }
}

/// The bundled sample maps: "MindMap Features" (opened on the first launch)
/// and "MindMap Roadmap", which link to each other (map links).
enum SampleMaps {
    static let featuresName = "MindMap Features"
    static let roadmapName = "MindMap Roadmap"
    static let featuresResource = "sample-features"
    static let roadmapResource = "sample-roadmap"

    static func archive(_ resource: String, in bundle: Bundle = .main) throws -> SamplePackageArchive {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try SamplePackageArchive.decode(Data(contentsOf: url))
    }

    /// `wrapper` with every map link that points at the package named
    /// `targetName` (relative path) also pointing at library map `targetID`
    /// (library maps find each other by ID, not by path).
    static func relinking(_ wrapper: FileWrapper, to targetName: String, libraryID targetID: UUID) throws -> FileWrapper {
        guard let data = wrapper.fileWrappers?[MindMapPackage.mapFileName]?.regularFileContents else {
            return wrapper
        }
        var map = try MindMapPackage.decode(data)
        func relink(_ node: inout Node) {
            if case var .map(reference)? = node.link,
               reference.relativePath.map(MapPaths.displayName(ofPath:)) == targetName
                || reference.displayName == targetName {
                reference.libraryID = targetID
                node.link = .map(reference)
            }
            for index in node.children.indices { relink(&node.children[index]) }
        }
        relink(&map.root)
        for index in map.floatingTopics.indices { relink(&map.floatingTopics[index].node) }
        MapPackageIO.replace(MindMapPackage.mapFileName, in: wrapper, with: try MindMapPackage.encode(map))
        return wrapper
    }
}

/// Where the samples are copied: the iCloud library or a folder of files.
enum SampleDestination: Equatable {
    case library
    case folder(URL)
}

/// Copies the bundled samples into the user's store (first launch, "Open
/// Sample") and remembers where they went, so "Open Sample" reopens the
/// same copy and only copies again when it was deleted.
@MainActor
struct SampleInstaller {
    var service: LibraryService
    var defaults: UserDefaults
    var bundle: Bundle = .main
    static let locationKey = "MindMap.samples.location"

    /// The installed "MindMap Features" package if it is still there.
    func installedFeaturesURL() -> URL? {
        guard let entry = defaults.dictionary(forKey: Self.locationKey) else { return nil }
        if let raw = entry["library"] as? String, let id = UUID(uuidString: raw) {
            return service.store.packageURL(for: .library(id))
        }
        if let data = entry["bookmark"] as? Data, let url = try? FolderBookmark.resolve(data),
           LastDocumentStore.itemExists(url) {
            return url
        }
        if let path = entry["path"] as? String, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The Features sample: the remembered copy, else a fresh copy of both
    /// samples in `destination`.
    func featuresURL(installingInto destination: SampleDestination) throws -> URL {
        if let url = installedFeaturesURL() { return url }
        return try install(into: destination)
    }

    /// Copies both samples (keeping their mutual map links) and returns the
    /// Features package.
    @discardableResult
    func install(into destination: SampleDestination) throws -> URL {
        let features = try SampleMaps.archive(SampleMaps.featuresResource, in: bundle)
        let roadmap = try SampleMaps.archive(SampleMaps.roadmapResource, in: bundle)
        switch destination {
        case .library:
            let featuresID = UUID()
            let roadmapID = existingLibraryRoadmap() ?? UUID()
            let featuresWrapper = try SampleMaps.relinking(features.fileWrapper(), to: roadmap.name,
                                                           libraryID: roadmapID)
            try service.store.importWrapper(featuresWrapper, title: features.name, id: featuresID)
            if let url = service.store.packageURL(for: .library(roadmapID)) {
                // Roadmap kept from an earlier copy: point its back link at the new Features.
                let relinked = try SampleMaps.relinking(try MapPackageIO.read(url), to: features.name,
                                                        libraryID: featuresID)
                try MapPackageIO.write(relinked, to: url)
                service.sync.checkForLocalChanges(roadmapID)
            } else {
                let roadmapWrapper = try SampleMaps.relinking(roadmap.fileWrapper(), to: features.name,
                                                              libraryID: featuresID)
                try service.store.importWrapper(roadmapWrapper, title: roadmap.name, id: roadmapID)
            }
            defaults.set(["library": featuresID.uuidString, "roadmap": roadmapID.uuidString], forKey: Self.locationKey)
            guard let url = service.store.packageURL(for: .library(featuresID)) else { throw CocoaError(.fileNoSuchFile) }
            return url
        case let .folder(folder):
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Same folder, original names: the relative map links keep working.
            let featuresURL = folder.appendingPathComponent(features.name + "." + MapPaths.fileExtension)
            for archive in [features, roadmap] {
                let url = folder.appendingPathComponent(archive.name + "." + MapPaths.fileExtension)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try MapPackageIO.write(archive.fileWrapper(), to: url)
                }
            }
            var entry: [String: Any] = ["path": featuresURL.path]
            if let bookmark = try? FolderBookmark.make(featuresURL) { entry["bookmark"] = bookmark }
            defaults.set(entry, forKey: Self.locationKey)
            return featuresURL
        }
    }

    /// The Roadmap of an earlier library install, if still there.
    private func existingLibraryRoadmap() -> UUID? {
        guard let raw = defaults.dictionary(forKey: Self.locationKey)?["roadmap"] as? String,
              let id = UUID(uuidString: raw), service.store.packageURL(for: .library(id)) != nil else { return nil }
        return id
    }
}
