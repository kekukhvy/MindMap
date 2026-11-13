import Foundation
import Testing
@testable import MindMap

/// WP13: Recent Files store, first-launch state machine (tour → samples
/// copied once → opened once; Open Sample re-copies), storage choice,
/// bundled samples, thumbnails.
@MainActor
struct WelcomeTests {
    // MARK: Fixtures

    /// Bookmarks that are just the path (no file system involved).
    struct PathCoder: BookmarkCoding {
        func bookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
        func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
            (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
        }
    }

    private func files(_ count: Int, in folder: URL) throws -> [URL] {
        try (0..<count).map { index in
            try StorageFixtures.writeFile(MindMap(root: Node(text: "Map \(index)")),
                                          to: folder.appendingPathComponent("Map \(index).mindmap"))
        }
    }

    private func flow(_ availability: LibraryAvailability = .available) async -> (WelcomeFlow, URL) {
        let service = await StorageFixtures.service(availability)
        let flow = WelcomeFlow(service: service, defaults: StorageFixtures.defaults())
        let folder = StorageFixtures.temporaryFolder("WelcomeFiles")
        flow.filesFolderOverride = folder
        return (flow, folder)
    }

    // MARK: Recent files

    @Test func recentsAreMostRecentFirstCappedAtTenAndDeduplicated() throws {
        let folder = StorageFixtures.temporaryFolder("Recents")
        let urls = try files(12, in: folder)
        let store = RecentMapsStore(defaults: StorageFixtures.defaults())
        for (index, url) in urls.enumerated() {
            store.note(url, date: Date(timeIntervalSince1970: Double(index)))
        }
        store.note(urls[3], date: Date(timeIntervalSince1970: 100)) // reopened → top, once
        let entries = store.entries()
        #expect(entries.count == 10)
        #expect(entries.first?.url.lastPathComponent == "Map 3.mindmap")
        #expect(entries.dropFirst().map(\.name) == ["Map 11", "Map 10", "Map 9", "Map 8", "Map 7", "Map 6", "Map 5",
                                                    "Map 4", "Map 2"])
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    @Test func missingFilesArePrunedAndRealBookmarksFollowMoves() throws {
        let folder = StorageFixtures.temporaryFolder("RecentsPrune")
        let urls = try files(3, in: folder)
        let store = RecentMapsStore(defaults: StorageFixtures.defaults())
        urls.forEach { store.note($0) }
        try FileManager.default.removeItem(at: urls[1])
        // Moved file: the bookmark still finds it.
        let moved = folder.appendingPathComponent("Renamed.mindmap")
        try FileManager.default.moveItem(at: urls[0], to: moved)
        let names = store.entries().map(\.name)
        #expect(names == ["Map 2", "Renamed"])
        // Pruned for good: the store no longer lists the deleted file.
        try StorageFixtures.writeFile(MindMap(), to: urls[1])
        #expect(!store.entries().map(\.name).contains("Map 1"))
    }

    @Test func removeFromListAlsoHidesSystemRecentsAndMergeKeepsOrder() throws {
        let folder = StorageFixtures.temporaryFolder("RecentsMerge")
        let urls = try files(4, in: folder)
        var store = RecentMapsStore(defaults: StorageFixtures.defaults())
        store.coder = PathCoder()
        store.note(urls[0], date: Date(timeIntervalSince1970: 1))
        store.note(urls[1], date: Date(timeIntervalSince1970: 2))
        // System recents (NSDocumentController): own entries first, new ones after.
        var merged = store.merged(with: [urls[2], urls[0], urls[3]])
        #expect(merged.map(\.name) == ["Map 1", "Map 0", "Map 2", "Map 3"])
        store.remove(urls[2])
        store.remove(urls[1])
        merged = store.merged(with: [urls[2], urls[0], urls[3]])
        #expect(merged.map(\.name) == ["Map 0", "Map 3"])
        // Opening it again lists it again.
        store.note(urls[2])
        #expect(store.merged(with: [urls[2]]).map(\.name) == ["Map 2", "Map 0"])
        // Library packages are excluded by the caller's filter.
        #expect(store.merged(with: [], excluding: { $0.lastPathComponent == "Map 2.mindmap" }).map(\.name) == ["Map 0"])
    }

    @Test func flowRecordsOnlyFilesNotLibraryMaps() async throws {
        let (flow, folder) = await flow()
        let file = try StorageFixtures.writeFile(MindMap(), to: folder.appendingPathComponent("Plain.mindmap"))
        let summary = try flow.service.store.createUntitledMap()
        let library = try #require(flow.service.store.packageURL(for: summary.location))
        let revision = flow.recentsRevision
        flow.noteOpened(file)
        flow.noteOpened(library)
        flow.noteOpened(nil)
        #expect(flow.recents.entries().map(\.name) == ["Plain"])
        #expect(flow.recentsRevision == revision + 1)
    }

    // MARK: First launch

    @Test func firstLaunchShowsTourThenWelcomeOrOldBehaviour() async throws {
        let (flow, _) = await flow()
        #expect(flow.launchAction() == .tour)
        #expect(flow.showsWelcomeOnLaunch)
        _ = try await flow.finishTour(choice: .library)
        #expect(flow.launchAction() == .welcome)
        flow.showsWelcomeOnLaunch = false
        #expect(flow.launchAction() == .reopenLast)
        // Persisted.
        #expect(WelcomeFlow(service: flow.service, defaults: flow.defaults).launchAction() == .reopenLast)
    }

    @Test func storageChoiceSetsTheMode() async throws {
        let (flow, _) = await flow()
        #expect(!flow.service.settings.hasExplicitChoice)
        #expect(flow.service.settings.storageMode == .library) // availability default
        _ = try await flow.finishTour(choice: .files)
        #expect(flow.service.settings.hasExplicitChoice)
        #expect(flow.service.settings.storageMode == .files)
        // A later tour can switch back; nil (closed) keeps it.
        _ = try await flow.finishTour(choice: .library)
        #expect(flow.service.settings.storageMode == .library)
        _ = try await flow.finishTour(choice: nil)
        #expect(flow.service.settings.storageMode == .library)
    }

    @Test func librarySamplesAreCopiedOnceOpenedOnceAndLinkedByID() async throws {
        let (flow, _) = await flow()
        let url = try #require(try await flow.finishTour(choice: .library))
        let maps = flow.service.store.maps()
        #expect(Set(maps.map(\.title)) == [SampleMaps.featuresName, SampleMaps.roadmapName])
        let featuresID = try #require(flow.service.libraryMapID(of: url))
        let roadmapID = try #require(maps.first { $0.title == SampleMaps.roadmapName }?.libraryID)
        // Mutual links by library ID (paths mean nothing in the library).
        let features = try StorageFixtures.map(at: url)
        #expect(features.root.text == "MindMap")
        #expect(mapLinks(features).contains { $0.libraryID == roadmapID })
        let roadmapURL = try #require(flow.service.store.packageURL(for: .library(roadmapID)))
        #expect(mapLinks(try StorageFixtures.map(at: roadmapURL)).contains { $0.libraryID == featuresID })
        // Every attachment came along.
        let archive = try SampleMaps.archive(SampleMaps.featuresResource)
        for path in archive.files.keys where path.hasPrefix("attachments/") {
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path))
        }

        // Never again: no second copy, nothing to open.
        #expect(try await flow.finishTour(choice: .library) == nil)
        #expect(flow.service.store.maps().count == 2)
        // Open Sample reopens the same copy.
        #expect(LaunchEnvironment.key(try await flow.sampleURL()) == LaunchEnvironment.key(url))
        #expect(flow.service.store.maps().count == 2)
    }

    @Test func openSampleRecopiesWhenDeleted() async throws {
        let (flow, _) = await flow()
        let url = try #require(try await flow.finishTour(choice: .library))
        let oldID = try #require(flow.service.libraryMapID(of: url))
        try flow.service.store.deleteMap(.library(oldID))
        #expect(flow.installer.installedFeaturesURL() == nil)
        let again = try await flow.sampleURL()
        let newID = try #require(flow.service.libraryMapID(of: again))
        #expect(newID != oldID)
        // The kept Roadmap now links back to the new copy; no duplicate Roadmap.
        let maps = flow.service.store.maps()
        #expect(maps.filter { $0.title == SampleMaps.roadmapName }.count == 1)
        let roadmapURL = try #require(maps.first { $0.title == SampleMaps.roadmapName }
            .flatMap { flow.service.store.packageURL(for: $0.location) })
        #expect(mapLinks(try StorageFixtures.map(at: roadmapURL)).contains { $0.libraryID == newID })
    }

    @Test func filesSamplesKeepTheirRelativeLinkAndRecopy() async throws {
        let (flow, folder) = await flow(.unavailable("test"))
        let url = try #require(try await flow.finishTour(choice: .files))
        #expect(flow.service.store.maps().isEmpty)
        #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        let roadmap = folder.appendingPathComponent(SampleMaps.roadmapName + ".mindmap")
        #expect(FileManager.default.fileExists(atPath: roadmap.path))
        let link = try #require(mapLinks(try StorageFixtures.map(at: url)).first)
        #expect(MapPaths.resolve(try #require(link.relativePath), from: url)?.lastPathComponent == roadmap.lastPathComponent)
        // Deleted → Open Sample copies it again (Roadmap untouched).
        try FileManager.default.removeItem(at: url)
        let again = try await flow.sampleURL()
        #expect(again.lastPathComponent == url.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: again.path))
    }

    @Test func bundledSamplesAreTheCommittedPackages() throws {
        let features = try SampleMaps.archive(SampleMaps.featuresResource)
        let roadmap = try SampleMaps.archive(SampleMaps.roadmapResource)
        #expect(features.name == SampleMaps.featuresName && roadmap.name == SampleMaps.roadmapName)
        let map = try MindMapPackage.read(features.fileWrapper())
        #expect(map.root.children.count == 10)
        #expect(map.referencedAttachmentFileNames.allSatisfy { features.files["attachments/" + $0] != nil })
        // Archive round trip through a folder.
        let folder = StorageFixtures.temporaryFolder("Archive").appendingPathComponent("Copy.mindmap")
        try MapPackageIO.write(features.fileWrapper(), to: folder)
        #expect(try SamplePackageArchive.make(from: folder).files == features.files)
    }

    // MARK: Thumbnails

    @Test func thumbnailsRenderPlainMapsAndSkipLockedOnes() async throws {
        let folder = StorageFixtures.temporaryFolder("Thumbs")
        let thumbnails = MapThumbnails(folder: folder.appendingPathComponent("cache"))
        let features = try SampleMaps.archive(SampleMaps.featuresResource)
        let url = folder.appendingPathComponent("Features.mindmap")
        try MapPackageIO.write(features.fileWrapper(), to: url)
        let image = try #require(await thumbnails.thumbnail(for: url))
        #expect(image.width == Int(MapThumbnails.size.width * 2) && image.height == Int(MapThumbnails.size.height * 2))
        #expect(thumbnails.cached(for: url) != nil)
        // Cached on disk: a fresh cache reads it without rendering.
        #expect(MapThumbnails(folder: folder.appendingPathComponent("cache")).cached(for: url) == nil)
        #expect(await MapThumbnails(folder: folder.appendingPathComponent("cache")).thumbnail(for: url) != nil)
        let locked = try StorageFixtures.lockedFile(MindMap(root: Node(text: "Secret")), files: [:],
                                                    key: LockCrypto.newKey(),
                                                    to: folder.appendingPathComponent("Locked.mindmap"))
        #expect(MapThumbnails.isLocked(locked))
        #expect(await thumbnails.thumbnail(for: locked) == nil)
    }

    @Test func locationTexts() {
        let drive = URL(fileURLWithPath: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Plans/X.mindmap")
        #expect(RecentLocation.text(for: drive) == "iCloud Drive › Plans")
        let app = URL(fileURLWithPath: "/Users/a/Library/Mobile Documents/iCloud~com~kekukh~MindMap/Documents/X.mindmap")
        #expect(RecentLocation.text(for: app) == "iCloud Drive › MindMap")
    }

    private func mapLinks(_ map: MindMap) -> [MapReference] {
        var result: [MapReference] = []
        func visit(_ node: Node) {
            if let reference = node.link?.mapReference { result.append(reference) }
            node.children.forEach(visit)
        }
        visit(map.root)
        map.floatingTopics.forEach { visit($0.node) }
        return result
    }
}
