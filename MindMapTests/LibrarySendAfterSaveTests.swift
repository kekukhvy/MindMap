import Foundation
import Testing
@testable import MindMap

/// A saved library map is sent at once, not when CloudKit's own scheduling
/// gets to it (2026-11-13: ~20 s from one device to the other). Saves go
/// through file coordination like a document save, and a real
/// `LibraryChangeMonitor` reports them, as in `LibraryService.start()`.
/// `MockSyncEngine` never sends by itself: every send counted here was
/// requested by the app.
@MainActor
@Suite(.serialized) struct LibrarySendAfterSaveTests {
    private static let debounce: Duration = .milliseconds(100)
    private static let poll: Duration = .milliseconds(20)
    /// Far below the ~20 s measured before the fix.
    private static let sendTimeout: TimeInterval = 5
    /// Long enough for a further (wrong) send to show up.
    private static let settle: Duration = .milliseconds(600)

    /// Device A with a library map already synced to the database, and a
    /// change monitor on A's library folder.
    private func syncedDevice() async throws -> (MockDevice, MockCloudDatabase, UUID, LibraryChangeMonitor) {
        let db = MockCloudDatabase()
        let device = MockDevice(database: db)
        device.sync.debounceInterval = Self.debounce
        let id = try device.libraryID(try device.store.importMap(MindMap(root: Node(text: "Plan"))))
        try await device.syncNow()
        let sync = device.sync
        let monitor = LibraryChangeMonitor(folder: device.cache.mapsFolder) { id in
            Task { @MainActor in sync.localMapDidChange(id) }
        }
        monitor.start()
        return (device, db, id, monitor)
    }

    /// An editor save of library map `id`: the package rewritten through
    /// file coordination (`LibraryCache.writePackage`).
    private func saveLibraryMap(_ text: String, id: UUID, on device: MockDevice) throws {
        try device.cache.writePackage(try MindMapPackage.fileWrapper(for: MindMap(root: Node(text: text))),
                                      for: id, title: text)
    }

    /// An editor save of a Files map (outside the library folder).
    private func saveFilesMap(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrapper = try MindMapPackage.fileWrapper(for: MindMap(root: Node(text: text)))
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do { try wrapper.write(to: target, options: .atomic, originalContentsURL: nil) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Self.sendTimeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: Self.poll)
        }
        return condition()
    }

    /// What another device gets for map `id` from the database.
    private func otherDeviceText(_ id: UUID, _ db: MockCloudDatabase) async throws -> String {
        let other = MockDevice(database: db)
        try await other.syncNow()
        return try other.map(id).root.text
    }

    // AC-sync-fast-1
    @Test func librarySaveIsSentAtOnce() async throws {
        let (device, db, id, monitor) = try await syncedDevice()
        defer { monitor.stop() }
        let sendsBefore = device.engine.sendCount

        try saveLibraryMap("Edited", id: id, on: device)

        #expect(try await waitUntil { device.engine.sendCount == sendsBefore + 1 })
        #expect(try await otherDeviceText(id, db) == "Edited")
    }

    // AC-sync-fast-2
    @Test func filesMapSaveDoesNotSend() async throws {
        let (device, db, id, monitor) = try await syncedDevice()
        defer { monitor.stop() }
        let sendsBefore = device.engine.sendCount
        let mapRecordsBefore = db.records.values.filter { $0.recordType == LibraryRecordType.map }.count

        try saveFilesMap("Files map", at: device.cache.root.appendingPathComponent("Files/Notes.mindmap"))
        // A library save after it: its send shows the monitor is delivering.
        try saveLibraryMap("Edited", id: id, on: device)
        #expect(try await waitUntil { device.engine.sendCount == sendsBefore + 1 })
        try await Task.sleep(for: Self.settle)

        #expect(device.engine.sendCount == sendsBefore + 1)
        #expect(db.records.values.filter { $0.recordType == LibraryRecordType.map }.count == mapRecordsBefore)
    }

    // AC-sync-fast-3
    @Test func savesWithinTheDebounceAreSentOnceAndALaterSaveAgain() async throws {
        let (device, db, id, monitor) = try await syncedDevice()
        defer { monitor.stop() }
        let sendsBefore = device.engine.sendCount

        try saveLibraryMap("First", id: id, on: device)
        try saveLibraryMap("Second", id: id, on: device)
        #expect(try await waitUntil { device.engine.sendCount == sendsBefore + 1 })
        try await Task.sleep(for: Self.settle)
        #expect(device.engine.sendCount == sendsBefore + 1)
        #expect(try await otherDeviceText(id, db) == "Second")

        try saveLibraryMap("Third", id: id, on: device)
        #expect(try await waitUntil { device.engine.sendCount == sendsBefore + 2 })
        #expect(try await otherDeviceText(id, db) == "Third")
    }
}
