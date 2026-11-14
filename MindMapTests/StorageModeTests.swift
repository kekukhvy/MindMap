import CryptoKit
import Foundation
import Testing
@testable import MindMap
@testable import struct MindMap.Attachment

/// WP14b: storage modes UI logic — New Map per mode, Import / Move /
/// Export / Duplicate round trips, map titles, mirror folder, library list,
/// sync status.
@MainActor
enum StorageFixtures {
    static func temporaryFolder(_ name: String = "StorageTest") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func defaults() -> UserDefaults {
        let name = "StorageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func service(_ availability: LibraryAvailability = .available) async -> LibraryService {
        let service = LibraryService(cache: LibraryCache(root: temporaryFolder("StorageLibrary")),
                                     accounts: FixedAccountProvider(result: availability),
                                     settings: StorageSettings(defaults: defaults()),
                                     mirrorSettings: LibraryMirrorSettings(defaults: defaults()))
        await service.refreshAvailability()
        return service
    }

    /// A `.mindmap` package on disk: map + attachment files by name.
    @discardableResult
    static func writeFile(_ map: MindMap, files: [String: Data] = [:], to url: URL) throws -> URL {
        var attachments: [String: FileWrapper] = [:]
        for (name, data) in files {
            attachments[name] = FileWrapper(regularFileWithContents: data)
            attachments[name]?.preferredFilename = name
        }
        try MindMapPackage.fileWrapper(for: map, attachments: attachments).write(to: url, options: [],
                                                                                  originalContentsURL: nil)
        return url
    }

    static func lockedFile(_ map: MindMap, files: [String: Data], key: SymmetricKey, to url: URL) throws -> URL {
        var attachments: [String: FileWrapper] = [:]
        for (name, data) in files {
            attachments[name] = FileWrapper(regularFileWithContents: data)
            attachments[name]?.preferredFilename = name
        }
        try LockedPackage.seal(map: map, attachments: attachments, header: LockHeader(keyID: UUID()), key: key,
                               cache: nil).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    static func map(at url: URL) throws -> MindMap {
        try MindMapPackage.read(FileWrapper(url: url, options: .immediate))
    }

    static func attachment(_ name: String, at url: URL) -> Data? {
        try? Data(contentsOf: url.appendingPathComponent("attachments").appendingPathComponent(name))
    }

    /// Every byte of every file below `url`.
    static func allBytes(below url: URL) -> [Data] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { ($0 as? URL).flatMap { try? Data(contentsOf: $0) } }
    }

    static func note(_ title: String, locked: Bool = false) -> Attachment {
        var note = Attachment(kind: .markdown, title: title)
        if locked {
            note.lockKeyID = UUID()
            note.fileName = "\(note.id.uuidString).md.enc"
        }
        return note
    }
}

@MainActor
@Suite struct StorageModeTests {
    @Test func newMapGoesToTheStoreOfTheStorageMode() async throws {
        let service = await StorageFixtures.service()
        #expect(service.settings.storageMode == .library) // available → library by default

        guard case let .library(first) = try MapCreation.prepareNewMap(service: service) else {
            Issue.record("library mode must create a library map")
            return
        }
        #expect(service.libraryMapID(of: first) != nil)
        #expect(first.lastPathComponent == "Untitled.mindmap")
        let map = try StorageFixtures.map(at: first)
        #expect(map.title == "Untitled")
        #expect(map.root.text == "Central Topic")
        guard case let .library(second) = try MapCreation.prepareNewMap(service: service) else {
            Issue.record("second map")
            return
        }
        #expect(second.lastPathComponent == "Untitled 2.mindmap")
        #expect(service.store.maps().map(\.title).sorted() == ["Untitled", "Untitled 2"])

        // Files mode: the platform's usual new document, nothing in the library.
        service.settings.storageMode = .files
        #expect(try MapCreation.prepareNewMap(service: service) == .file)
        #expect(service.store.maps().count == 2)

        // Without iCloud the default is files; an explicit library choice
        // still creates library maps (kept here, uploaded later).
        let offline = await StorageFixtures.service(.unavailable("not signed in to iCloud"))
        #expect(try MapCreation.prepareNewMap(service: offline) == .file)
        offline.settings.storageMode = .library
        guard case .library = try MapCreation.prepareNewMap(service: offline) else {
            Issue.record("explicit library mode")
            return
        }
        #expect(offline.status == .unavailable("not signed in to iCloud"))
    }

    @Test func importExportAndDuplicateRoundTripAPlainMap() async throws {
        let service = await StorageFixtures.service()
        let folder = StorageFixtures.temporaryFolder()
        var note = StorageFixtures.note("Plain note")
        note.fileName = "\(note.id.uuidString).md"
        let locked = StorageFixtures.note("Locked note", locked: true)
        let file = Attachment(kind: .file, title: "data.bin", fileName: "\(UUID().uuidString).bin")
        let original = MindMap(root: Node(text: "Central", children: [
            Node(text: "Notes", attachments: [note, locked, file]),
        ]))
        let files = [note.fileName: Data("# Hello\nworld".utf8), locked.fileName: Data([1, 2, 3, 4]),
                     file.fileName: Data([9, 8, 7])]
        let source = try StorageFixtures.writeFile(original, files: files,
                                                   to: folder.appendingPathComponent("Project Plan.mindmap"))

        // Import: same map (+ title = file name), same attachment bytes.
        let summary = try service.store.importPackage(at: source)
        #expect(summary.title == "Project Plan")
        let id = try #require(summary.libraryID)
        let imported = try #require(service.store.packageURL(for: summary.location))
        #expect(imported.lastPathComponent == "Project Plan.mindmap")
        var expected = original
        expected.title = "Project Plan"
        #expect(try StorageFixtures.map(at: imported) == expected)
        for (name, data) in files { #expect(StorageFixtures.attachment(name, at: imported) == data) }
        #expect(FileManager.default.fileExists(atPath: source.path)) // import copies
        #expect(service.store.maps().map(\.title) == ["Project Plan"])
        #expect(service.sync.state.maps[id]?.title == "Project Plan")

        // Export: a .mindmap file with the same content.
        let exported = folder.appendingPathComponent("Exported.mindmap")
        try service.store.export(id, to: exported)
        #expect(try StorageFixtures.map(at: exported) == expected)
        for (name, data) in files { #expect(StorageFixtures.attachment(name, at: exported) == data) }
        // …and back in: still the same map.
        let again = try service.store.importPackage(at: exported, title: "Round Trip")
        var roundTrip = expected
        roundTrip.title = "Round Trip"
        #expect(try StorageFixtures.map(at: try #require(service.store.packageURL(for: again.location))) == roundTrip)

        // Duplicate: new map "<title> copy", same content.
        let copy = try service.store.duplicateMap(id)
        #expect(copy.title == "Project Plan copy")
        #expect(copy.libraryID != id)
        var copied = expected
        copied.title = "Project Plan copy"
        let copyURL = try #require(service.store.packageURL(for: copy.location))
        #expect(try StorageFixtures.map(at: copyURL) == copied)
        #expect(StorageFixtures.attachment(file.fileName, at: copyURL) == files[file.fileName])
        #expect(service.store.maps().count == 3)
    }

    @Test func lockedMapsMoveAsCiphertext() async throws {
        let service = await StorageFixtures.service()
        let folder = StorageFixtures.temporaryFolder()
        let key = LockCrypto.newKey()
        var note = StorageFixtures.note("Secret note")
        note.fileName = "\(note.id.uuidString).md"
        let map = MindMap(root: Node(text: "Secret Plan", children: [Node(text: "Hidden topic", attachments: [note])]))
        let source = try StorageFixtures.lockedFile(map, files: [note.fileName: Data("classified words".utf8)],
                                                    key: key, to: folder.appendingPathComponent("Vault.mindmap"))

        let summary = try service.store.importPackage(at: source)
        #expect(summary.isLocked)
        let url = try #require(service.store.packageURL(for: summary.location))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(LockHeader.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("map.json").path))
        #expect(service.store.maps().first?.title == "Vault") // package name, no plaintext title
        #expect(service.store.maps().first?.isLocked == true)
        for data in StorageFixtures.allBytes(below: url) {
            for secret in ["Secret Plan", "Hidden topic", "classified words"] {
                #expect(data.range(of: Data(secret.utf8)) == nil)
            }
        }
        // Still opens with the key; export keeps it sealed.
        #expect(try LockedPackage.open(FileWrapper(url: url, options: .immediate), key: key).map == map)
        let exported = folder.appendingPathComponent("Vault export.mindmap")
        try service.store.export(try #require(summary.libraryID), to: exported)
        #expect(try LockedPackage.open(FileWrapper(url: exported, options: .immediate), key: key).map == map)
    }

    @Test func moveMapsBetweenFilesAndTheLibrary() async throws {
        let service = await StorageFixtures.service()
        let folder = StorageFixtures.temporaryFolder()
        let a = try StorageFixtures.writeFile(MindMap(root: Node(text: "A")), to: folder.appendingPathComponent("Alpha.mindmap"))
        let b = try StorageFixtures.writeFile(MindMap(root: Node(text: "B")), to: folder.appendingPathComponent("Beta.mindmap"))
        let broken = folder.appendingPathComponent("Broken.mindmap")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        // Files → library, originals to the Trash.
        let moved = LibraryMoves.importFiles([a, b, broken], into: service.store, trashOriginals: true)
        #expect(moved.succeeded == ["Alpha", "Beta"])
        #expect(moved.failed == ["Broken"])
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(Set(service.store.maps().map(\.title)) == ["Alpha", "Beta"])

        // Library → folder; an open map stays in the library.
        let target = StorageFixtures.temporaryFolder("Export")
        try StorageFixtures.writeFile(MindMap(root: Node(text: "Old")), to: target.appendingPathComponent("Alpha.mindmap"))
        let betaURL = try #require(service.store.maps().first { $0.title == "Beta" }
            .flatMap { service.store.packageURL(for: $0.location) })
        let exported = LibraryMoves.exportAll(service.store, to: target, removeFromLibrary: true) { url in
            LaunchEnvironment.key(url) == LaunchEnvironment.key(betaURL)
        }
        #expect(Set(exported.succeeded) == ["Alpha", "Beta"])
        #expect(exported.keptOpen == ["Beta"])
        #expect(service.store.maps().map(\.title) == ["Beta"])
        #expect(try StorageFixtures.map(at: target.appendingPathComponent("Alpha 2.mindmap")).root.text == "A")
        #expect(try StorageFixtures.map(at: target.appendingPathComponent("Alpha.mindmap")).root.text == "Old")
        #expect(try StorageFixtures.map(at: target.appendingPathComponent("Beta.mindmap")).root.text == "B")
    }

    @Test func libraryTitlesRenameAndSyncToOtherDevices() async throws {
        // Model: one undoable step; blank = unset; LibraryTitle prefers it.
        let model = MindMapModel(map: MindMap(root: Node(text: "Root text")))
        let undo = UndoManager()
        undo.groupsByEvent = false
        #expect(LibraryTitle.title(of: model.map) == "Root text")
        #expect(model.setMapTitle("  Q3 Plan ", undoManager: undo))
        #expect(model.map.title == "Q3 Plan")
        #expect(LibraryTitle.title(of: model.map) == "Q3 Plan")
        #expect(!model.setMapTitle("Q3 Plan", undoManager: undo))
        #expect(undo.undoActionName == "Rename Map")
        undo.undo()
        #expect(model.map.title == nil)

        // JSON: optional "title".
        let data = try MindMapPackage.encode(MindMap(root: Node(text: "R"), title: "T"))
        #expect(try MindMapPackage.decode(data).title == "T")
        #expect(try MindMapPackage.decode(MindMapPackage.encode(MindMap())).title == nil)

        // Two devices: renamed on A (title + package), B's package follows.
        let db = MockCloudDatabase()
        let a = MockDevice(database: db), b = MockDevice(database: db)
        let summary = try a.store.createUntitledMap()
        let id = try a.libraryID(summary)
        try await a.syncNow()
        try await b.syncNow()
        #expect(b.cache.packageURL(for: id)?.lastPathComponent == "Untitled.mindmap")
        var map = try a.map(id)
        map.title = "Roadmap / 2027"
        try a.save(map, id: id, modified: Date())
        try a.cache.renamePackage(of: id, toTitle: "Roadmap / 2027")
        #expect(a.cache.packageURL(for: id)?.lastPathComponent == "Roadmap - 2027.mindmap")
        try await a.syncNow()
        try await b.syncNow()
        #expect(try b.map(id).title == "Roadmap / 2027")
        #expect(b.cache.packageURL(for: id)?.lastPathComponent == "Roadmap - 2027.mindmap")
        #expect(b.store.maps().map(\.title) == ["Roadmap / 2027"])

        // Merge: title changed on one side, a topic on the other.
        let base = MindMap(root: Node(text: "R", children: [Node(text: "X")]), title: "Old")
        var local = base
        local.title = "New"
        var remote = base
        remote.root.children[0].text = "Y"
        let merged = MapMerge.merge(base: base, local: .init(map: local, modified: Date(timeIntervalSince1970: 1)),
                                    remote: .init(map: remote, modified: Date(timeIntervalSince1970: 2))).map
        #expect(merged.title == "New")
        #expect(merged.root.children.first?.text == "Y")
    }

    @Test func syncStatusFollowsAccountNetworkAndPendingUploads() async throws {
        #expect(LibrarySyncStatus.make(availability: .checking, isOnline: true, hasPendingChanges: false) == .checking)
        #expect(LibrarySyncStatus.make(availability: .available, isOnline: true, hasPendingChanges: false) == .synced)
        #expect(LibrarySyncStatus.make(availability: .available, isOnline: true, hasPendingChanges: true) == .syncing)
        #expect(LibrarySyncStatus.make(availability: .available, isOnline: false, hasPendingChanges: true) == .offline)
        let unavailable = LibrarySyncStatus.make(availability: .unavailable("not signed in to iCloud"), isOnline: true,
                                                 hasPendingChanges: false)
        #expect(unavailable.title == "iCloud unavailable — not signed in to iCloud")
        #expect(unavailable.fixHint?.contains("sign in to iCloud") == true)
        #expect(LibrarySyncStatus.unavailable("this build is not signed for iCloud").fixHint?.contains("Xcode") == true)
        #expect(LibrarySyncStatus.synced.fixHint == nil)

        // Per map: pending until the engine uploaded it.
        let service = await StorageFixtures.service()
        let db = MockCloudDatabase()
        let engine = MockSyncEngine(database: db)
        engine.sync = service.sync
        service.attachEngine(engine)
        let summary = try service.store.createUntitledMap()
        let id = try #require(summary.libraryID)
        #expect(service.status(of: id) == .syncing)
        #expect(service.status == .syncing)
        try await engine.sendChanges()
        #expect(service.status(of: id) == .synced)
        #expect(service.status == .synced)
        #expect(service.libraryMapID(of: service.store.packageURL(for: summary.location)) == id)
        #expect(service.libraryMapID(of: FileManager.default.temporaryDirectory.appendingPathComponent("x.mindmap")) == nil)
    }
}

@MainActor
@Suite struct LibraryListTests {
    private func summary(_ title: String, _ minutes: Double?, locked: Bool = false) -> MapSummary {
        MapSummary(location: .library(UUID()), title: title,
                   modified: minutes.map { Date(timeIntervalSinceReferenceDate: 800_000_000 + $0 * 60) },
                   isLocked: locked)
    }

    @Test func sortsByDateOrNameAndSearchesWords() {
        let maps = [summary("Map 10", 5), summary("map 2", 30), summary("Café Plans", 20, locked: true),
                    summary("Budget", nil), summary("Alpha", 20)]
        #expect(LibraryListModel.items(maps, search: "", sort: .modified).map(\.title)
            == ["map 2", "Alpha", "Café Plans", "Map 10", "Budget"])
        #expect(LibraryListModel.items(maps, search: "", sort: .title).map(\.title)
            == ["Alpha", "Budget", "Café Plans", "map 2", "Map 10"])
        #expect(LibraryListModel.items(maps, search: "cafe", sort: .modified).map(\.title) == ["Café Plans"])
        #expect(LibraryListModel.items(maps, search: "MAP", sort: .title).map(\.title) == ["map 2", "Map 10"])
        #expect(LibraryListModel.items(maps, search: "plans café", sort: .title).first?.isLocked == true)
        #expect(LibraryListModel.items(maps, search: "map zzz", sort: .title).isEmpty)
        #expect(LibraryListModel.items(maps, search: "   ", sort: .title).count == 5)
    }

    @Test func storeListsTitlesLockedNamesAndNewestFirst() async throws {
        let service = await StorageFixtures.service()
        let first = try service.store.importMap(MindMap(root: Node(text: "Root"), title: "Older"))
        let firstURL = try #require(service.store.packageURL(for: first.location))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: firstURL.appendingPathComponent("map.json").path)
        service.sync.checkForLocalChanges(try #require(first.libraryID))
        _ = try service.store.importMap(MindMap(root: Node(text: "Newest root")))
        let maps = LibraryListModel.items(service.store.maps(), search: "", sort: .modified)
        #expect(maps.map(\.title) == ["Newest root", "Older"])
        #expect(service.store.uniqueTitle(base: "older") == "older 2")
    }
}

@MainActor
@Suite struct LibraryMirrorTests {
    @Test func markdownOutlineHasHeadingsBulletsTasksLinksAndNotes() {
        var note = StorageFixtures.note("n")
        note.fileName = "n.md"
        var task = Node(text: "Call Bob")
        task.task = TaskInfo(isDone: true)
        var web = Node(text: "Site")
        web.link = .web(URL(string: "https://example.com")!)
        let map = MindMap(root: Node(text: "Central", children: [
            Node(text: "Goals", children: [Node(text: "Ship\nv1", children: [task], attachments: [note]), web]),
        ]), floatingTopics: [FloatingTopic(node: Node(text: "Loose idea"), position: .zero)])
        let text = MarkdownExport.markdown(of: map, title: "Plan") { _ in "line one\n\nline two" }
        #expect(text == """
            # Plan

            Central

            ## Goals

            - Ship v1
              line one

              line two
              - [x] Call Bob
            - [Site](https://example.com)

            ## Loose idea

            """)
    }

    // AC-imgfix-2
    @Test func mirrorCopiesNoteImagesToTheLinkedPathAndRemovesThemWithTheNote() throws {
        var note = StorageFixtures.note("Pic")
        note.fileName = "\(note.id.uuidString).md"
        let imageName = NoteImage.fileName(noteID: note.id, fileExtension: NoteImage.pngExtension)
        let lockedNote = StorageFixtures.note("Hidden", locked: true)
        let lockedImage = NoteImage.fileName(noteID: lockedNote.id, fileExtension: NoteImage.pngExtension)
        let png = NoteImageTests.samplePNG(width: 20, height: 10)
        let folder = StorageFixtures.temporaryFolder()
        let file = try StorageFixtures.writeFile(
            MindMap(root: Node(text: "Central", children: [Node(text: "Topic", attachments: [note, lockedNote])])),
            files: [note.fileName: Data(NoteImage.link(for: imageName).utf8), imageName: png,
                    lockedImage + ".enc": Data("sealed".utf8)],
            to: folder.appendingPathComponent("Pics.mindmap"))
        let mirror = StorageFixtures.temporaryFolder("Mirror")
        let source = LibraryMirrorWriter.Source(title: "Pics", packageURL: file, isLocked: false)
        let linked = mirror.appendingPathComponent(NoteImage.linkFolder + imageName)

        let report = try LibraryMirrorWriter.write([source], to: mirror, includeMapCopies: false)
        #expect(try Data(contentsOf: linked) == png)
        #expect(report.written.contains(NoteImage.linkFolder + imageName))
        #expect(!FileManager.default.fileExists(atPath: mirror.appendingPathComponent(NoteImage.linkFolder + lockedImage + ".enc").path))
        #expect(!FileManager.default.fileExists(atPath: mirror.appendingPathComponent(NoteImage.linkFolder + lockedImage).path))
        let markdown = try String(contentsOf: mirror.appendingPathComponent("Pics.md"), encoding: .utf8)
        #expect(markdown.contains(NoteImage.link(for: imageName)))

        let removed = try LibraryMirrorWriter.write([], to: mirror, includeMapCopies: false)
        #expect(removed.removed.contains(NoteImage.linkFolder + imageName))
        #expect(!FileManager.default.fileExists(atPath: linked.path))
    }

    @Test func mirrorWritesPlainMarkdownButNeverLockedContent() async throws {
        let service = await StorageFixtures.service()
        let key = LockCrypto.newKey()
        // Plain map with a plain note and a locked note.
        var plainNote = StorageFixtures.note("Visible")
        plainNote.fileName = "\(plainNote.id.uuidString).md"
        let lockedNote = StorageFixtures.note("Hidden", locked: true)
        let lockedNoteCipher = try LockCrypto.seal(Data("locked note secret".utf8), key: key, context: "test")
        let folder = StorageFixtures.temporaryFolder()
        let plainFile = try StorageFixtures.writeFile(
            MindMap(root: Node(text: "Central", children: [Node(text: "Topic", attachments: [plainNote, lockedNote])])),
            files: [plainNote.fileName: Data("visible note text".utf8), lockedNote.fileName: lockedNoteCipher],
            to: folder.appendingPathComponent("Notes Map.mindmap"))
        let plain = try service.store.importPackage(at: plainFile)
        // Locked map.
        let lockedFile = try StorageFixtures.lockedFile(MindMap(root: Node(text: "Top secret topic")), files: [:],
                                                        key: key, to: folder.appendingPathComponent("Vault.mindmap"))
        _ = try service.store.importPackage(at: lockedFile)

        let mirror = StorageFixtures.temporaryFolder("Mirror")
        try "my own note".write(to: mirror.appendingPathComponent("Mine.md"), atomically: true, encoding: .utf8)
        try "user file".write(to: mirror.appendingPathComponent("Notes Map.md"), atomically: true, encoding: .utf8)
        let settings = service.mirror.settings
        settings.isEnabled = true
        try settings.setFolder(mirror)
        let report = try #require(service.mirror.updateNow())
        // Name taken by a user file → numbered; locked map → no .md.
        #expect(report.written == ["Notes Map 2.md"])
        let markdown = try String(contentsOf: mirror.appendingPathComponent("Notes Map 2.md"), encoding: .utf8)
        #expect(markdown.contains("# Notes Map"))
        #expect(markdown.contains("## Topic"))
        #expect(markdown.contains("visible note text"))
        #expect(markdown.contains(MarkdownExport.lockedNotePlaceholder))
        #expect(service.mirror.lastResult?.hasPrefix("Mirrored 2 maps") == true)

        // With .mindmap copies: locked ones stay encrypted.
        settings.includesMapCopies = true
        let second = try #require(service.mirror.updateNow())
        #expect(second.unchanged == ["Notes Map 2.md"])
        #expect(Set(second.written) == ["Notes Map 2.mindmap", "Vault.mindmap"])
        for data in StorageFixtures.allBytes(below: mirror) {
            for secret in ["locked note secret", "Top secret topic"] {
                #expect(data.range(of: Data(secret.utf8)) == nil)
            }
        }
        #expect(try LockedPackage.open(FileWrapper(url: mirror.appendingPathComponent("Vault.mindmap"),
                                                   options: .immediate), key: key).map.root.text == "Top secret topic")
        #expect(service.mirror.updateNow()?.written == [])

        // Map deleted from the library → its mirror files go; user files stay.
        try service.store.deleteMap(plain.location)
        let third = try #require(service.mirror.updateNow())
        #expect(Set(third.removed) == ["Notes Map 2.md", "Notes Map 2.mindmap"])
        #expect(try String(contentsOf: mirror.appendingPathComponent("Mine.md"), encoding: .utf8) == "my own note")
        #expect(try String(contentsOf: mirror.appendingPathComponent("Notes Map.md"), encoding: .utf8) == "user file")
        #expect(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("Vault.mindmap").path))

        // Off: nothing is written.
        settings.isEnabled = false
        #expect(service.mirror.updateNow() == nil)
    }
}
