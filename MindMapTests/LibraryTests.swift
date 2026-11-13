import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import MindMap

// MARK: - Mocks

/// In-memory "private database" shared by several mock devices: stores
/// copies of saved records (assets copied into its own folder), detects
/// conflicts by the Map record's `revision` (stands in for change tags),
/// cascades map deletions to attachments, serves zone changes by token.
@MainActor
final class MockCloudDatabase {
    let assetFolder: URL
    private(set) var records: [CKRecord.ID: CKRecord] = [:]
    private var changeLog: [(seq: Int, id: CKRecord.ID, type: String)] = []
    private var sequence = 0
    var saveCount = 0

    init() {
        assetFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MockCloud-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: assetFolder, withIntermediateDirectories: true)
    }

    enum SaveResult {
        case saved(CKRecord)
        case failed(LibrarySaveFailure)
    }

    func save(_ record: CKRecord) -> SaveResult {
        if record.recordType == LibraryRecordType.map {
            let sent = Int(record[MapRecordField.revision] as? Int64 ?? 0)
            if let existing = records[record.recordID] {
                let stored = Int(existing[MapRecordField.revision] as? Int64 ?? 0)
                if sent != stored + 1 { return .failed(.conflict(serverRecord: copy(existing))) }
            } else if sent != 1 {
                return .failed(.unknownItem)
            }
        }
        // swiftlint:disable:next force_cast
        let stored = record.copy() as! CKRecord
        for key in stored.allKeys() {
            if let asset = stored[key] as? CKAsset, let url = asset.fileURL {
                let target = assetFolder.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.copyItem(at: url, to: target)
                stored[key] = CKAsset(fileURL: target)
            }
        }
        records[record.recordID] = stored
        log(record.recordID, record.recordType)
        saveCount += 1
        return .saved(copy(stored))
    }

    func delete(_ id: CKRecord.ID) -> Bool {
        guard let record = records.removeValue(forKey: id) else { return false }
        log(id, record.recordType)
        if record.recordType == LibraryRecordType.map {
            for (childID, child) in records
            where (child[AttachmentRecordField.map] as? CKRecord.Reference)?.recordID == id {
                records[childID] = nil
                log(childID, LibraryRecordType.attachment)
            }
        }
        return true
    }

    func changes(since token: Int) -> (modified: [CKRecord], deleted: [(CKRecord.ID, CKRecord.RecordType)], token: Int) {
        var latest: [CKRecord.ID: String] = [:]
        var order: [CKRecord.ID] = []
        for entry in changeLog where entry.seq > token {
            if latest[entry.id] == nil { order.append(entry.id) }
            latest[entry.id] = entry.type
        }
        var modified: [CKRecord] = []
        var deleted: [(CKRecord.ID, CKRecord.RecordType)] = []
        for id in order {
            if let record = records[id] { modified.append(copy(record)) } else { deleted.append((id, latest[id] ?? "")) }
        }
        return (modified, deleted, sequence)
    }

    func mapRecord(_ id: UUID) -> CKRecord? { records[LibraryRecordID.map(id)] }

    var attachmentRecords: [CKRecord] { records.values.filter { $0.recordType == LibraryRecordType.attachment } }

    private func log(_ id: CKRecord.ID, _ type: String) {
        sequence += 1
        changeLog.append((sequence, id, type))
    }

    private func copy(_ record: CKRecord) -> CKRecord {
        // swiftlint:disable:next force_cast
        record.copy() as! CKRecord
    }
}

/// `LibrarySyncEngine` over `MockCloudDatabase` (sends rounds until
/// nothing is pending, like CKSyncEngine rescheduling after a merge).
@MainActor
final class MockSyncEngine: LibrarySyncEngine {
    let database: MockCloudDatabase
    weak var sync: LibrarySync?
    private var pending: [LibraryRecordChange] = []
    private var token = 0

    init(database: MockCloudDatabase) {
        self.database = database
    }

    func add(_ changes: [LibraryRecordChange]) {
        for change in changes where !pending.contains(change) { pending.append(change) }
    }

    var pendingChanges: [LibraryRecordChange] { pending }

    private(set) var sendCount = 0
    private(set) var fetchCount = 0

    func sendChanges() async throws {
        sendCount += 1
        var rounds = 0
        while !pending.isEmpty, rounds < 10, let sync {
            rounds += 1
            let batch = pending
            pending = []
            var saved: [CKRecord] = []
            var failed: [(CKRecord, LibrarySaveFailure)] = []
            var deleted: [CKRecord.ID] = []
            var failedDeletes: [(CKRecord.ID, LibrarySaveFailure)] = []
            for change in batch {
                switch change {
                case let .save(id):
                    guard let record = sync.record(for: id) else { continue }
                    switch database.save(record) {
                    case let .saved(stored): saved.append(stored)
                    case let .failed(failure): failed.append((record, failure))
                    }
                case let .delete(id):
                    if database.delete(id) { deleted.append(id) } else { failedDeletes.append((id, .unknownItem)) }
                }
            }
            await sync.handleSent(saved: saved, failed: failed, deleted: deleted, failedDeletes: failedDeletes)
        }
    }

    func fetchChanges() async throws {
        fetchCount += 1
        let changes = database.changes(since: token)
        token = changes.token
        await sync?.handleFetched(modifications: changes.modified, deletions: changes.deleted)
    }
}

/// One device: its own cache folder, sync core and mock engine.
@MainActor
struct MockDevice {
    let cache: LibraryCache
    let sync: LibrarySync
    let engine: MockSyncEngine
    let store: LibraryMapStore

    /// `cache`: an existing device's folder (the app launched again).
    init(database: MockCloudDatabase, cache existing: LibraryCache? = nil) {
        cache = existing ?? LibraryCache(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTest-\(UUID().uuidString)"))
        sync = LibrarySync(cache: cache)
        engine = MockSyncEngine(database: database)
        engine.sync = sync
        sync.attach(engine)
        store = LibraryMapStore(sync: sync)
    }

    func syncNow() async throws {
        try await engine.sendChanges()
        try await engine.fetchChanges()
        try await engine.sendChanges()
    }

    func map(_ id: UUID) throws -> MindMap {
        let url = try #require(cache.packageURL(for: id))
        return try MindMapPackage.read(FileWrapper(url: url, options: .immediate))
    }

    func attachmentData(_ id: UUID, _ name: String) -> Data? {
        cache.packageURL(for: id).flatMap {
            try? Data(contentsOf: $0.appendingPathComponent("attachments").appendingPathComponent(name))
        }
    }

    /// Simulates an editor save (package rewritten, map.json dated `modified`).
    func save(_ map: MindMap, id: UUID, modified: Date, files: [String: Data] = [:]) throws {
        let url = try #require(cache.packageURL(for: id))
        var attachments: [String: FileWrapper] = [:]
        let existing = try FileWrapper(url: url, options: .immediate)
        for (name, wrapper) in existing.fileWrappers?["attachments"]?.fileWrappers ?? [:]
        where map.referencedAttachmentFileNames.contains(name) {
            attachments[name] = FileWrapper(regularFileWithContents: wrapper.regularFileContents ?? Data())
        }
        for (name, data) in files { attachments[name] = FileWrapper(regularFileWithContents: data) }
        for (name, wrapper) in attachments { wrapper.preferredFilename = name }
        try cache.writePackage(try MindMapPackage.fileWrapper(for: map, attachments: attachments), for: id, title: "")
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: url.appendingPathComponent("map.json").path)
        sync.checkForLocalChanges(id)
    }

    func libraryID(_ summary: MapSummary) throws -> UUID {
        guard case let .library(id) = summary.location else { throw CocoaError(.fileNoSuchFile) }
        return id
    }
}

private func topic(_ text: String, in map: MindMap) -> Node? {
    func find(_ node: Node) -> Node? {
        if node.text == text { return node }
        for child in node.children { if let found = find(child) { return found } }
        return nil
    }
    return find(map.root) ?? map.floatingTopics.lazy.compactMap { find($0.node) }.first
}

private func rename(_ text: String, to newText: String, in map: inout MindMap) {
    func walk(_ node: inout Node) {
        if node.text == text { node.text = newText }
        for index in node.children.indices { walk(&node.children[index]) }
    }
    walk(&map.root)
}

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A two-topic library map on device A, synced to device B.
@MainActor
private func sharedMap(_ db: MockCloudDatabase) async throws -> (MockDevice, MockDevice, UUID) {
    let a = MockDevice(database: db), b = MockDevice(database: db)
    let summary = try a.store.importMap(MindMap(root: Node(text: "Plan", children: [Node(text: "X"), Node(text: "Y")])))
    let id = try a.libraryID(summary)
    try await a.syncNow()
    try await b.syncNow()
    return (a, b, id)
}

// MARK: - Cache, records, store

@MainActor
@Suite struct LibraryCacheTests {
    @Test func cacheRoundTripAndLookups() throws {
        let device = MockDevice(database: MockCloudDatabase())
        let summary = try device.store.createMap(titled: "Project Plan")
        let id = try device.libraryID(summary)
        let url = try #require(device.store.packageURL(for: summary.location))
        #expect(url.lastPathComponent == "Project Plan.mindmap")
        #expect(url.path.contains("/Maps/\(id.uuidString)/"))
        #expect(try device.map(id).root.text == "Project Plan")
        #expect(device.cache.mapID(containing: url) == id)
        #expect(device.cache.mapID(containing: url.appendingPathComponent("map.json")) == id)
        #expect(device.cache.mapID(containing: FileManager.default.temporaryDirectory) == nil)
        #expect(device.store.maps().map(\.title) == ["Project Plan"])

        // The editor's package format: a normal document can open it.
        let wrapper = try FileWrapper(url: url, options: .immediate)
        let model = MindMapModel()
        try model.load(package: wrapper)
        #expect(model.map.root.text == "Project Plan")

        try device.store.deleteMap(summary.location)
        #expect(device.cache.packageURL(for: id) == nil)
        #expect(device.store.maps().isEmpty)
    }

    @Test func recordConversionRoundTripsThePackage() async throws {
        let db = MockCloudDatabase()
        let a = MockDevice(database: db), b = MockDevice(database: db)
        var note = Attachment(kind: .markdown, title: "Note")
        note.fileName = "\(note.id.uuidString).md"
        let map = MindMap(root: Node(text: "Trip", children: [Node(text: "Packing", attachments: [note])]))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("# Packing\n- socks".utf8).write(to: source)
        let id = try a.libraryID(try a.store.importMap(map, attachments: [note.fileName: source]))

        let record = try #require(a.sync.record(for: LibraryRecordID.map(id)))
        #expect(record.recordType == "Map")
        #expect(record[MapRecordField.title] as? String == "Trip")
        #expect(record[MapRecordField.encrypted] as? Int64 == 0)
        let payload = try Data(contentsOf: try #require((record[MapRecordField.payload] as? CKAsset)?.fileURL))
        #expect(try MindMapPackage.decode(payload) == map)
        let hashes = LibraryRecordCodec.decodeHashes(record[MapRecordField.attachmentHashes] as? String)
        #expect(hashes == [note.fileName: LibraryHash.sha256(Data("# Packing\n- socks".utf8))])
        #expect(a.engine.pendingChanges == [.save(LibraryRecordID.map(id)),
                                            .save(LibraryRecordID.attachment(map: id, fileName: note.fileName))])

        try await a.syncNow()
        #expect(db.mapRecord(id) != nil)
        #expect(db.attachmentRecords.count == 1)
        #expect(a.sync.state.maps[id]?.isOnServer == true)
        #expect(a.engine.pendingChanges.isEmpty)

        try await b.syncNow()
        #expect(try b.map(id) == map)
        #expect(b.attachmentData(id, note.fileName) == Data("# Packing\n- socks".utf8))
        #expect(b.store.maps().map(\.title) == ["Trip"])
        #expect(b.engine.pendingChanges.isEmpty) // nothing echoed back
        #expect(LibraryRecordID.parse(LibraryRecordID.attachment(map: id, fileName: note.fileName))
            == .attachment(map: id, fileName: note.fileName))
    }

    @Test func unchangedSaveUploadsNothing() async throws {
        let db = MockCloudDatabase()
        let (a, _, id) = try await sharedMap(db)
        let saves = db.saveCount
        try a.save(try a.map(id), id: id, modified: t0)
        try await a.syncNow()
        #expect(db.saveCount == saves)
    }
}

// MARK: - Merge through sync

@MainActor
@Suite struct LibraryMergeSyncTests {
    @Test func differentTopicsEditedOnTwoDevicesMerge() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var onA = try a.map(id)
        rename("X", to: "X from A", in: &onA)
        try a.save(onA, id: id, modified: t0)
        var onB = try b.map(id)
        rename("Y", to: "Y from B", in: &onB)
        try b.save(onB, id: id, modified: t0.addingTimeInterval(10))

        try await a.syncNow()
        try await b.syncNow() // conflict -> merge -> upload merged
        try await a.syncNow()

        for device in [a, b] {
            let merged = try device.map(id)
            #expect(merged.root.children.map(\.text) == ["X from A", "Y from B"])
        }
        #expect(b.sync.lastConflicts[id] == [])
    }

    @Test func sameTopicTextKeepsNewerAndAConflictCopy() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var onA = try a.map(id)
        rename("X", to: "X older (A)", in: &onA)
        try a.save(onA, id: id, modified: t0)
        var onB = try b.map(id)
        rename("X", to: "X newer (B)", in: &onB)
        try b.save(onB, id: id, modified: t0.addingTimeInterval(60))

        try await a.syncNow()
        try await b.syncNow()
        try await a.syncNow()

        for device in [a, b] {
            let merged = try device.map(id)
            #expect(merged.root.children.map(\.text) == ["X newer (B)", "X older (A) (conflicting edit)", "Y"])
        }
        let conflicts = try #require(b.sync.lastConflicts[id])
        #expect(conflicts.count == 1)
        if case .text = conflicts.first?.kind {} else { Issue.record("expected a text conflict") }
    }

    @Test func deleteOnOneDeviceVersusEditOnTheOtherKeepsTheEdit() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var onA = try a.map(id)
        onA.root.children.removeAll { $0.text == "X" }
        try a.save(onA, id: id, modified: t0.addingTimeInterval(60))
        var onB = try b.map(id)
        rename("X", to: "X edited", in: &onB)
        try b.save(onB, id: id, modified: t0)

        try await a.syncNow()
        try await b.syncNow()
        try await a.syncNow()
        for device in [a, b] {
            #expect(try device.map(id).root.children.map(\.text) == ["X edited", "Y"])
        }
        let conflict = try #require(b.sync.lastConflicts[id]?.first)
        #expect(conflict.kind == .deleteVsEdit)
    }

    @Test func attachmentsAddedOnBothDevicesAreKept() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var noteA = Attachment(kind: .markdown, title: "A note")
        noteA.fileName = "\(noteA.id.uuidString).md"
        var onA = try a.map(id)
        onA.root.children[0].attachments = [noteA]
        try a.save(onA, id: id, modified: t0, files: [noteA.fileName: Data("from A".utf8)])

        let fileB = Attachment(kind: .file, title: "photo.png", originalExtension: "png")
        var onB = try b.map(id)
        onB.root.children[1].attachments = [fileB]
        try b.save(onB, id: id, modified: t0.addingTimeInterval(5), files: [fileB.fileName: Data([1, 2, 3])])

        try await a.syncNow()
        try await b.syncNow()
        try await a.syncNow()
        for device in [a, b] {
            let merged = try device.map(id)
            #expect(merged.root.children[0].attachments.map(\.id) == [noteA.id])
            #expect(merged.root.children[1].attachments.map(\.id) == [fileB.id])
            #expect(device.attachmentData(id, noteA.fileName) == Data("from A".utf8))
            #expect(device.attachmentData(id, fileB.fileName) == Data([1, 2, 3]))
        }
        #expect(db.attachmentRecords.count == 2)
    }

    // AC-img-7
    @Test func aNoteImageIsUploadedAndSurvivesAMerge() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var note = Attachment(kind: .markdown, title: "Shot")
        note.fileName = "\(note.id.uuidString).md"
        let image = NoteImage.fileName(noteID: note.id, fileExtension: "png")
        let png = NoteImageTests.samplePNG()
        var onA = try a.map(id)
        onA.root.children[0].attachments = [note]
        try a.save(onA, id: id, modified: t0, files: [note.fileName: Data("![](attachments/\(image))".utf8), image: png])
        #expect(a.engine.pendingChanges.contains(.save(LibraryRecordID.attachment(map: id, fileName: image))))
        // B changed another topic meanwhile: A's note arrives through a merge.
        var onB = try b.map(id)
        rename("Y", to: "Y from B", in: &onB)
        try b.save(onB, id: id, modified: t0.addingTimeInterval(5))

        try await a.syncNow()
        try await b.syncNow()
        try await a.syncNow()
        for device in [a, b] {
            #expect(try device.map(id).root.children[0].attachments.map(\.id) == [note.id])
            #expect(device.attachmentData(id, image) == png)
        }
        #expect(db.attachmentRecords.count == 2)
    }

    @Test func sameAttachmentEditedOnBothDevicesKeepsTheNewerFile() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var note = Attachment(kind: .markdown, title: "Note")
        note.fileName = "\(note.id.uuidString).md"
        var withNote = try a.map(id)
        withNote.root.children[0].attachments = [note]
        try a.save(withNote, id: id, modified: t0, files: [note.fileName: Data("v1".utf8)])
        try await a.syncNow()
        try await b.syncNow()
        #expect(b.attachmentData(id, note.fileName) == Data("v1".utf8))

        var onA = try a.map(id)
        rename("Y", to: "Y (A)", in: &onA) // map changes too
        try a.save(onA, id: id, modified: t0.addingTimeInterval(100), files: [note.fileName: Data("A's text".utf8)])
        try b.save(try b.map(id), id: id, modified: t0.addingTimeInterval(50), files: [note.fileName: Data("B's text".utf8)])
        try await b.syncNow()
        try await a.syncNow() // A is newer: its text wins
        try await b.syncNow()
        for device in [a, b] {
            #expect(device.attachmentData(id, note.fileName) == Data("A's text".utf8))
            #expect(try device.map(id).root.children.map(\.text) == ["X", "Y (A)"])
        }
    }

    @Test func remoteDeletionRemovesAnUnchangedMap() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        try a.store.deleteMap(.library(id))
        try await a.syncNow()
        #expect(db.mapRecord(id) == nil)
        try await b.syncNow()
        #expect(b.cache.packageURL(for: id) == nil)
        #expect(b.sync.state.maps[id] == nil)
    }

    @Test func remoteDeletionOfAMapEditedHereKeepsAndReuploadsIt() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        try a.store.deleteMap(.library(id))
        try await a.syncNow()
        var onB = try b.map(id)
        rename("X", to: "still needed", in: &onB)
        try b.save(onB, id: id, modified: t0)
        try await b.syncNow()
        #expect(try b.map(id).root.children.first?.text == "still needed")
        #expect(db.mapRecord(id) != nil)
        try await a.syncNow()
        #expect(try a.map(id).root.children.first?.text == "still needed")
    }
}

// MARK: - Locked maps

@MainActor
@Suite struct LibraryLockTests {
    private func lockedPackage(_ map: MindMap, key: SymmetricKey, header: LockHeader,
                               files: [String: Data]) throws -> FileWrapper {
        var attachments: [String: FileWrapper] = [:]
        for (name, data) in files {
            attachments[name] = FileWrapper(regularFileWithContents: data)
            attachments[name]?.preferredFilename = name
        }
        return try LockedPackage.seal(map: map, attachments: attachments, header: header, key: key, cache: nil)
    }

    @Test func lockedMapUploadsOnlyCiphertext() async throws {
        let db = MockCloudDatabase()
        let a = MockDevice(database: db), b = MockDevice(database: db)
        let key = LockCrypto.newKey()
        let header = LockHeader(keyID: UUID())
        var note = Attachment(kind: .markdown, title: "Secret note")
        note.fileName = "\(note.id.uuidString).md"
        let map = MindMap(root: Node(text: "Secret Plan", children: [Node(text: "Hidden topic", attachments: [note])]))
        let id = UUID()
        try a.cache.writePackage(try lockedPackage(map, key: key, header: header,
                                                   files: [note.fileName: Data("classified words".utf8)]),
                                 for: id, title: LibraryTitle.lockedMap)
        a.sync.checkForLocalChanges(id)
        try await a.syncNow()

        let record = try #require(db.mapRecord(id))
        #expect(record[MapRecordField.encrypted] as? Int64 == 1)
        #expect(record[MapRecordField.title] == nil)
        #expect(record[MapRecordField.lockHeader] as? Data != nil)
        var uploaded: [Data] = [try Data(contentsOf: try #require((record[MapRecordField.payload] as? CKAsset)?.fileURL))]
        for attachment in db.attachmentRecords {
            #expect((attachment[AttachmentRecordField.fileName] as? String)?.hasSuffix(".enc") == true)
            uploaded.append(try Data(contentsOf: try #require((attachment[AttachmentRecordField.file] as? CKAsset)?.fileURL)))
        }
        #expect(db.attachmentRecords.count == 1)
        for data in uploaded {
            for secret in ["Secret Plan", "Hidden topic", "classified words", "Secret note"] {
                #expect(data.range(of: Data(secret.utf8)) == nil)
            }
        }
        #expect(a.store.maps().first?.isLocked == true)
        #expect(a.store.maps().first?.title == LibraryTitle.lockedMap)

        // Device B gets the locked package; it opens with the key.
        try await b.syncNow()
        let url = try #require(b.cache.packageURL(for: id))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("map.json").path))
        let opened = try LockedPackage.open(try FileWrapper(url: url, options: .immediate), key: key)
        #expect(opened.map == map)
        #expect(b.cache.base(for: id) == nil) // no plaintext merge base
    }

    @Test func lockedMapChangedOnBothDevicesKeepsBothVersions() async throws {
        let db = MockCloudDatabase()
        let a = MockDevice(database: db), b = MockDevice(database: db)
        let key = LockCrypto.newKey()
        let header = LockHeader(keyID: UUID())
        let id = UUID()
        let base = MindMap(root: Node(text: "Vault"))
        try a.cache.writePackage(try lockedPackage(base, key: key, header: header, files: [:]), for: id, title: "x")
        a.sync.checkForLocalChanges(id)
        try await a.syncNow()
        try await b.syncNow()

        func edit(_ device: MockDevice, _ text: String, _ modified: Date) throws {
            let url = try #require(device.cache.packageURL(for: id))
            try device.cache.writePackage(try lockedPackage(MindMap(root: Node(text: text)), key: key, header: header,
                                                            files: [:]), for: id, title: "x")
            try FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: url.appendingPathComponent("map.json.enc").path)
            device.sync.checkForLocalChanges(id)
        }
        try edit(a, "Vault A", t0)
        try edit(b, "Vault B", t0.addingTimeInterval(30))
        try await a.syncNow()
        try await b.syncNow() // B newer: keeps the map, A's version becomes a copy
        try await a.syncNow()

        for device in [a, b] {
            let ids = device.cache.mapIDs()
            #expect(ids.count == 2)
            var texts: [String] = []
            for mapID in ids {
                let url = try #require(device.cache.packageURL(for: mapID))
                texts.append(try LockedPackage.open(try FileWrapper(url: url, options: .immediate), key: key).map.root.text)
            }
            #expect(texts.sorted() == ["Vault A", "Vault B"])
            let opened = try LockedPackage.open(try FileWrapper(url: try #require(device.cache.packageURL(for: id)),
                                                                options: .immediate), key: key)
            #expect(opened.map.root.text == "Vault B")
        }
        let copy = try #require(b.cache.mapIDs().first { $0 != id })
        #expect(b.cache.packageURL(for: copy)?.lastPathComponent == "Locked Map (conflict copy).mindmap")
    }
}

// MARK: - Engine callbacks

/// Stands in for CKSyncEngine's rule that a delegate callback must not await
/// `fetchChanges()` / `sendChanges()` (it traps): callbacks are delivered
/// with `inCallback` bound, which tasks started from them inherit.
@MainActor
final class CallbackCheckingEngine: LibrarySyncEngine {
    @TaskLocal static var inCallback = false
    private(set) var reentrantCalls = 0
    private(set) var fetchCount = 0
    private var fetchWaiter: CheckedContinuation<Void, Never>?

    func add(_ changes: [LibraryRecordChange]) {}

    var pendingChanges: [LibraryRecordChange] { [] }

    func sendChanges() async throws {
        if Self.inCallback { reentrantCalls += 1 }
    }

    func fetchChanges() async throws {
        if Self.inCallback { reentrantCalls += 1 }
        fetchCount += 1
        fetchWaiter?.resume()
        fetchWaiter = nil
    }

    func untilFetched() async {
        guard fetchCount == 0 else { return }
        await withCheckedContinuation { fetchWaiter = $0 }
    }
}

@MainActor
@Suite struct LibraryEngineCallbackTests {
    @Test(.timeLimit(.minutes(1)))
    func conflictWithoutServerPayloadFetchesOutsideTheEngineCallback() async {
        let cache = LibraryCache(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTest-\(UUID().uuidString)"))
        let sync = LibrarySync(cache: cache)
        let engine = CallbackCheckingEngine()
        sync.attach(engine)
        let recordID = LibraryRecordID.map(UUID())
        let sent = CKRecord(recordType: LibraryRecordType.map, recordID: recordID)
        let serverWithoutPayload = CKRecord(recordType: LibraryRecordType.map, recordID: recordID)

        await CallbackCheckingEngine.$inCallback.withValue(true) {
            await sync.handleSent(saved: [], failed: [(sent, .conflict(serverRecord: serverWithoutPayload))],
                                  deleted: [], failedDeletes: [])
        }
        await engine.untilFetched()

        #expect(engine.fetchCount == 1)
        #expect(engine.reentrantCalls == 0)
    }
}

// MARK: - Stuck sync (Mac and iPad out of sync, 2026-11-13)

/// Stands in for an open iPad editor: `UIDocument` gives up its file to a
/// writer by running a block synchronously on the main thread.
final class MainThreadRelinquishingPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    /// How long the main thread may stay busy before it counts as blocked.
    static let mainThreadWait: TimeInterval = 3
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private(set) var mainThreadWasBlocked = false

    init(url: URL) {
        presentedItemURL = url
    }

    func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        let reached = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { reached.signal() }
        if reached.wait(timeout: .now() + Self.mainThreadWait) == .timedOut { mainThreadWasBlocked = true }
        writer(nil)
    }
}

@MainActor
@Suite struct LibraryStuckSyncTests {
    private let readOnly = 0o555
    private let writable = 0o755

    /// iPad: the fetched version of the open map was written by a
    /// coordinated write on the main thread, which the open document needs
    /// to give the file up: the app hung until the watchdog killed it.
    @Test(.timeLimit(.minutes(1)))
    func fetchedVersionOfAMapOpenInAnEditorIsWrittenWithoutBlockingTheMainThread() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var onA = try a.map(id)
        rename("X", to: "X (A)", in: &onA)
        try a.save(onA, id: id, modified: t0)
        try await a.syncNow()

        let editor = MainThreadRelinquishingPresenter(url: try #require(b.cache.packageURL(for: id)))
        NSFileCoordinator.addFilePresenter(editor)
        defer { NSFileCoordinator.removeFilePresenter(editor) }
        try await b.engine.fetchChanges()

        #expect(!editor.mainThreadWasBlocked)
        #expect(try b.map(id).root.children.map(\.text) == ["X (A)", "Y"])
    }

    /// iPad: after the kill the fetched version stayed staged, and the
    /// engine does not fetch it again.
    @Test func versionFetchedBeforeTheAppWasKilledIsIntegratedAtTheNextLaunch() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var onA = try a.map(id)
        rename("X", to: "X (A)", in: &onA)
        try a.save(onA, id: id, modified: t0)
        try await a.syncNow()

        // The package write fails (stands in for the kill while it waited).
        let folder = try #require(b.cache.packageURL(for: id)).deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: readOnly], ofItemAtPath: folder)
        try await b.engine.fetchChanges()
        try FileManager.default.setAttributes([.posixPermissions: writable], ofItemAtPath: folder)
        #expect(try b.map(id).root.children.map(\.text) == ["X", "Y"])

        let relaunched = MockDevice(database: db, cache: b.cache)
        await relaunched.sync.integrateStagedChanges()
        #expect(try relaunched.map(id).root.children.map(\.text) == ["X (A)", "Y"])
    }

    /// Mac: a note marked "downloading" although the server has the file
    /// uploaded from here blocked every later upload of the map.
    @Test func fileTheServerHasFromHereIsNotWaitedFor() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var note = Attachment(kind: .markdown, title: "Note")
        note.fileName = "\(note.id.uuidString).md"
        var withNote = try a.map(id)
        withNote.root.children[0].attachments = [note]
        try a.save(withNote, id: id, modified: t0, files: [note.fileName: Data("v1".utf8)])
        try await a.syncNow()
        var state = a.cache.loadState()
        state.maps[id]?.missingAttachments = [note.fileName]
        a.cache.saveState(state)

        let relaunched = MockDevice(database: db, cache: a.cache)
        var onA = try relaunched.map(id)
        rename("X", to: "X (A)", in: &onA)
        try relaunched.save(onA, id: id, modified: t0.addingTimeInterval(10))
        try await relaunched.engine.sendChanges()
        try await b.syncNow()

        #expect(try b.map(id).root.children.map(\.text) == ["X (A)", "Y"])
        #expect(b.attachmentData(id, note.fileName) == Data("v1".utf8))
    }

    /// Mac: an upload queued before a fetched version's files arrived went
    /// out without them; the server's map lost the note and this device
    /// later rolled back to the staged version.
    @Test func uploadQueuedBeforeFilesStartedDownloadingWaitsForThem() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var note = Attachment(kind: .markdown, title: "Note")
        note.fileName = "\(note.id.uuidString).md"
        var onA = try a.map(id)
        rename("X", to: "X (A)", in: &onA)
        onA.root.children[0].attachments = [note]
        try a.save(onA, id: id, modified: t0, files: [note.fileName: Data("from A".utf8)])
        try await a.syncNow()

        var onB = try b.map(id)
        rename("Y", to: "Y (B)", in: &onB)
        try b.save(onB, id: id, modified: t0.addingTimeInterval(10)) // upload queued
        await b.sync.handleFetched(modifications: [try #require(db.mapRecord(id))], deletions: [])
        try await b.engine.sendChanges()
        await b.sync.handleFetched(modifications: [try #require(db.attachmentRecords.first)], deletions: [])
        try await b.engine.sendChanges()
        try await a.syncNow()

        for device in [a, b] {
            #expect(try device.map(id).root.children.map(\.text) == ["X (A)", "Y (B)"])
            #expect(device.attachmentData(id, note.fileName) == Data("from A".utf8))
        }
    }

    /// Mac: the state an earlier build left (its own upload went out while
    /// an older fetched version was still staged): a later fetch of a file
    /// of that map must not roll the map back to the staged version.
    @Test func olderStagedVersionDoesNotRollTheMapBack() async throws {
        let db = MockCloudDatabase()
        let (a, b, id) = try await sharedMap(db)
        var note = Attachment(kind: .markdown, title: "Note")
        note.fileName = "\(note.id.uuidString).md"
        var onA = try a.map(id)
        rename("X", to: "X (A)", in: &onA)
        onA.root.children[0].attachments = [note]
        try a.save(onA, id: id, modified: t0, files: [note.fileName: Data("from A".utf8)])
        try await a.syncNow()

        var onB = try b.map(id)
        rename("Y", to: "Y (B)", in: &onB)
        try b.save(onB, id: id, modified: t0.addingTimeInterval(10))
        await b.sync.handleFetched(modifications: [try #require(db.mapRecord(id))], deletions: [])
        let package = try #require(b.cache.packageURL(for: id))
        let merged = try #require(try LibraryPackageSnapshot.read(at: package, mapID: id))
        var state = b.cache.loadState()
        state.maps[id]?.revision += 1 // the earlier build uploaded the merged version
        state.maps[id]?.syncedPayloadHash = merged.payloadHash
        b.cache.saveState(state)

        let relaunched = MockDevice(database: db, cache: b.cache)
        await relaunched.sync.handleFetched(modifications: [try #require(db.attachmentRecords.first)], deletions: [])
        #expect(try relaunched.map(id).root.children.map(\.text) == ["X (A)", "Y (B)"])
    }
}

// MARK: - Availability, settings, links

@MainActor
@Suite struct LibraryAvailabilityTests {
    private func defaults() -> UserDefaults {
        let name = "LibraryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func accountUnavailableDegradesGracefully() async throws {
        let cache = LibraryCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = LibraryService(cache: cache, accounts: FixedAccountProvider(result: .unavailable("not signed in to iCloud")),
                                     settings: StorageSettings(defaults: defaults()))
        await service.refreshAvailability()
        #expect(service.availability == .unavailable("not signed in to iCloud"))
        #expect(service.availability.statusText == "iCloud Sync unavailable — not signed in to iCloud")
        #expect(service.settings.storageMode == .files)
        #expect(service.sync.engine == nil)
        // The local library still works (uploads once iCloud is back).
        let summary = try service.store.createMap(titled: "Offline")
        #expect(service.store.packageURL(for: summary.location) != nil)
        #expect(service.store.maps().count == 1)

        // Attaching an engine later uploads what was made offline.
        let db = MockCloudDatabase()
        let engine = MockSyncEngine(database: db)
        engine.sync = service.sync
        service.attachEngine(engine)
        try await engine.sendChanges()
        #expect(db.mapRecord(try MockDevice(database: db).libraryID(summary)) != nil)
    }

    private func offlineService() -> LibraryService {
        LibraryService(
            cache: LibraryCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            accounts: FixedAccountProvider(result: .unavailable("not signed in to iCloud")),
            settings: StorageSettings(defaults: defaults()))
    }

    @Test func syncNowWithEngineScansFetchesAndSends() async throws {
        let db = MockCloudDatabase()
        let service = offlineService()
        let engine = MockSyncEngine(database: db)
        engine.sync = service.sync
        service.attachEngine(engine)
        let summary = try service.store.createMap(titled: "Pending")
        await service.syncNow()
        #expect(engine.fetchCount == 1)
        #expect(engine.sendCount == 1)
        #expect(db.mapRecord(try MockDevice(database: db).libraryID(summary)) != nil)
    }

    @Test func syncNowWithoutEngineRefreshesAvailability() async {
        let service = offlineService()
        #expect(service.availability != .unavailable("not signed in to iCloud"))
        await service.syncNow()
        #expect(service.availability == .unavailable("not signed in to iCloud"))
    }

    @Test func activationRunsSyncNow() async {
        let service = offlineService()
        let engine = MockSyncEngine(database: MockCloudDatabase())
        engine.sync = service.sync
        service.attachEngine(engine)
        await service.appDidBecomeActive().value
        #expect(engine.fetchCount == 1)
        #expect(engine.sendCount == 1)
    }

    @Test func storageModeDefaultsToLibraryOnlyWhenAvailableAndPersistsTheChoice() async {
        let store = defaults()
        let available = LibraryService(
            cache: LibraryCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            accounts: FixedAccountProvider(result: .available), settings: StorageSettings(defaults: store))
        await available.refreshAvailability()
        #expect(available.settings.storageMode == .library)
        #expect(!available.settings.hasExplicitChoice)

        available.settings.storageMode = .files
        let reloaded = StorageSettings(defaults: store)
        reloaded.isLibraryAvailable = true
        #expect(reloaded.storageMode == .files)
        #expect(reloaded.hasExplicitChoice)
    }

    @Test func unsignedBuildNeverTouchesCloudKit() async {
        let none = CloudKitAccountProvider(containerIdentifier: nil)
        #expect(await none.availability() == .unavailable("this build is not signed for iCloud"))
        #expect(none.makeContainer() == nil)
        #if os(macOS)
        // Local (ad-hoc) test host: no iCloud entitlement -> no CKContainer.
        if !CloudKitAccountProvider.hasCloudKitEntitlement("iCloud.com.kekukh.MindMap") {
            let provider = CloudKitAccountProvider(containerIdentifier: "iCloud.com.kekukh.MindMap")
            #expect(await provider.availability() == .unavailable("this build is not signed for iCloud"))
        }
        #endif
        #expect(CloudKitAccountProvider.availability(for: .noAccount) == .unavailable("not signed in to iCloud"))
    }

    @Test func libraryMapLinksResolveByID() throws {
        let device = MockDevice(database: MockCloudDatabase())
        let summary = try device.store.createMap(titled: "Linked")
        let id = try device.libraryID(summary)
        let url = try #require(device.cache.packageURL(for: id))
        var resolver = MapLinkResolver()
        resolver.libraryPackage = { device.cache.packageURL(for: $0) }
        resolver.libraryMapID = { device.cache.mapID(containing: $0) }

        let reference = resolver.reference(to: url, from: nil, targetTopicID: nil)
        #expect(reference.libraryID == id)
        #expect(reference.relativePath == nil)
        #expect(reference.displayName == "Linked")
        #expect(reference.pathDescription == "iCloud Library")
        #expect(resolver.resolve(reference, documentURL: nil) == .found(url, refreshed: nil))

        // JSON round trip; an older reader sees a usable map link too.
        let link = TopicLink.map(reference)
        let data = try JSONEncoder().encode(link)
        #expect(String(decoding: data, as: UTF8.self).contains("\"library\""))
        #expect(try JSONDecoder().decode(TopicLink.self, from: data) == link)

        try device.store.deleteMap(summary.location)
        #expect(resolver.resolve(reference, documentURL: nil) == .missing)
    }

    @Test func changeMonitorMapsURLsToLibraryIDs() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let monitor = LibraryChangeMonitor(folder: folder) { _ in }
        let id = UUID()
        #expect(monitor.mapID(of: folder.appendingPathComponent("\(id.uuidString)/A.mindmap/map.json")) == id)
        #expect(monitor.mapID(of: folder.appendingPathComponent("not-a-uuid/A.mindmap")) == nil)
        #expect(monitor.mapID(of: FileManager.default.temporaryDirectory) == nil)
    }
}

// MARK: - Pure merge

@Suite struct MapMergeTests {
    private let older = Date(timeIntervalSinceReferenceDate: 0)
    private let newer = Date(timeIntervalSinceReferenceDate: 100)

    @Test func movesOnBothSidesThatWouldCycleFallBackToLocal() {
        let a = Node(text: "A"), b = Node(text: "B")
        let base = MindMap(root: Node(text: "R", children: [a, b]))
        var local = base // B under A
        local.root.children = [Node(id: a.id, text: "A", children: [b])]
        var remote = base // A under B
        remote.root.children = [Node(id: b.id, text: "B", children: [a])]
        let result = MapMerge.merge(base: base, local: .init(map: local, modified: older),
                                    remote: .init(map: remote, modified: newer))
        #expect(result.map.root.children.count == 1)
        let ids = Set(result.map.root.children.map(\.id) + result.map.root.children.flatMap { $0.children.map(\.id) })
        #expect(ids == [a.id, b.id])
    }

    @Test func fieldsMergeKeyByKeyAndRelationshipsFollowTheirTopics() {
        let x = Node(text: "X"), y = Node(text: "Y")
        let relation = Relationship(from: x.id, to: y.id)
        let base = MindMap(root: Node(text: "R", children: [x, y]), relationships: [relation])
        var local = base
        local.root.children[0].colorTag = .red          // local: colour of X
        var remote = base
        remote.root.children[0].isCollapsed = true      // remote: collapse X
        remote.root.children.remove(at: 1)              // remote: delete Y (unchanged locally)
        let result = MapMerge.merge(base: base, local: .init(map: local, modified: newer),
                                    remote: .init(map: remote, modified: older))
        #expect(result.map.root.children.count == 1)
        #expect(result.map.root.children[0].colorTag == .red)
        #expect(result.map.root.children[0].isCollapsed)
        #expect(result.map.relationships.isEmpty)
        #expect(result.conflicts.isEmpty)
    }

    @Test func floatingTopicsMergeTheirPositionAndText() {
        let floating = FloatingTopic(node: Node(text: "Idea"), position: CGPoint(x: 10, y: 10))
        let base = MindMap(root: Node(text: "R"), floatingTopics: [floating])
        var local = base
        local.floatingTopics[0].position = CGPoint(x: 50, y: 60)
        var remote = base
        remote.floatingTopics[0].node.text = "Better idea"
        let result = MapMerge.merge(base: base, local: .init(map: local, modified: older),
                                    remote: .init(map: remote, modified: newer))
        #expect(result.map.floatingTopics.count == 1)
        #expect(result.map.floatingTopics[0].position == CGPoint(x: 50, y: 60))
        #expect(result.map.floatingTopics[0].node.text == "Better idea")
    }

    @Test func centralTopicTextConflictAddsTheCopyAsChild() {
        let base = MindMap(root: Node(text: "R"))
        var local = base
        local.root.text = "Local"
        var remote = base
        remote.root.text = "Remote"
        let result = MapMerge.merge(base: base, local: .init(map: local, modified: newer),
                                    remote: .init(map: remote, modified: older))
        #expect(result.map.root.text == "Local")
        #expect(result.map.root.children.map(\.text) == ["Remote (conflicting edit)"])
    }
}
