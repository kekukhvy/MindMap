#if os(iOS)
import Foundation
import Testing
@testable import MindMap

/// iPad: a library map open in a window while library sync writes a newer
/// version of its package (another device's edit). The open map shows it
/// without being left; when the document missed the change (file presenters
/// get no messages while the app is suspended), reopening it after Welcome
/// or the window becoming active shows it, and an autosave never writes
/// the stale map over the newer file.
@MainActor
@Suite(.serialized)
struct LibraryRevertTests {
    private static let originalText = "Topic"
    private static let otherDeviceText = "Added on Mac"
    private static let iPadText = "Added on iPad"
    private static let poll = 100
    /// Seconds the open document gets to notice the change (under 1 s observed).
    private static let revertTimeout: TimeInterval = 5
    /// Lets UIDocument see an undo step (dirty state) or a missed change settle.
    private static let settle = 300

    private struct Fixture {
        let cache: LibraryCache
        let id: UUID
        let url: URL
        let map: MindMap
    }

    private func makeLibraryMap() throws -> Fixture {
        let cache = LibraryCache(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRevert-\(UUID().uuidString)"))
        let id = UUID()
        let map = MindMap(root: Node(text: Self.originalText))
        let url = try cache.writePackage(try MindMapPackage.fileWrapper(for: map), for: id, title: Self.originalText)
        return Fixture(cache: cache, id: id, url: url, map: map)
    }

    /// Writes the other device's version the way `LibrarySync` does (off
    /// the main thread, `LibraryCache.writePackage`); returns the new topic.
    private func writeOtherDeviceVersion(_ fixture: Fixture) async throws -> UUID {
        var map = fixture.map
        let topic = Node(text: Self.otherDeviceText)
        map.root.children.append(topic)
        let wrapper = try MindMapPackage.fileWrapper(for: map)
        let cache = fixture.cache, id = fixture.id, title = Self.originalText
        _ = try await Task.detached { try cache.writePackage(wrapper, for: id, title: title) }.value
        return topic.id
    }

    /// The same write while the document is not a file presenter (the app
    /// suspended), so it never hears of it.
    private func writeOtherDeviceVersionUnnoticed(_ fixture: Fixture, by document: MindMapUIDocument) async throws -> UUID {
        NSFileCoordinator.removeFilePresenter(document)
        let topic = try await writeOtherDeviceVersion(fixture)
        NSFileCoordinator.addFilePresenter(document)
        try await Task.sleep(for: .milliseconds(Self.settle))
        return topic
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Self.revertTimeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(Self.poll))
        }
        return condition()
    }

    private func open(_ fixture: Fixture) async throws -> (DocumentSession, MindMapUIDocument) {
        let session = DocumentSession()
        #expect(await session.openAndWait(fixture.url))
        return (session, try #require(session.document))
    }

    @Test func openMapShowsVersionWrittenBySync() async throws {
        let fixture = try makeLibraryMap()
        let (_, document) = try await open(fixture)
        let topic = try await writeOtherDeviceVersion(fixture)
        #expect(try await waitUntil { document.model.map.node(withID: topic) != nil })
        #expect(await document.close())
    }

    @Test func reopeningAfterWelcomeShowsMissedVersion() async throws {
        let fixture = try makeLibraryMap()
        let (session, document) = try await open(fixture)
        let topic = try await writeOtherDeviceVersionUnnoticed(fixture, by: document)
        #expect(document.model.map.node(withID: topic) == nil)
        session.isShowingWelcome = true
        #expect(await session.openAndWait(fixture.url))
        #expect(session.document?.model.map.node(withID: topic) != nil)
        #expect(await document.close())
    }

    @Test func becomingActiveShowsMissedVersion() async throws {
        let fixture = try makeLibraryMap()
        let (session, document) = try await open(fixture)
        let topic = try await writeOtherDeviceVersionUnnoticed(fixture, by: document)
        session.didBecomeActive()
        #expect(try await waitUntil { document.model.map.node(withID: topic) != nil })
        #expect(await document.close())
    }

    @Test func autosaveKeepsMissedVersion() async throws {
        let fixture = try makeLibraryMap()
        let (_, document) = try await open(fixture)
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        _ = document.model.addChild(to: document.model.root.id, text: Self.iPadText, undoManager: undo)
        try await Task.sleep(for: .milliseconds(Self.settle))
        let topic = try await writeOtherDeviceVersionUnnoticed(fixture, by: document)
        #expect(document.hasUnsavedChanges)
        #expect(await document.autosave())
        #expect(MapThumbnails.readMap(fixture.url)?.node(withID: topic) != nil)
        #expect(document.model.map.node(withID: topic) != nil)
        #expect(await document.close())
    }

    @Test func closingKeepsMissedVersion() async throws {
        let fixture = try makeLibraryMap()
        let (_, document) = try await open(fixture)
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        _ = document.model.addChild(to: document.model.root.id, text: Self.iPadText, undoManager: undo)
        try await Task.sleep(for: .milliseconds(Self.settle))
        let topic = try await writeOtherDeviceVersionUnnoticed(fixture, by: document)
        #expect(await document.close())
        #expect(MapThumbnails.readMap(fixture.url)?.node(withID: topic) != nil)
    }

    /// The document's own save is not taken for a change elsewhere (a
    /// revert would clear the undo history).
    @Test func ownSaveIsNotARevert() async throws {
        let fixture = try makeLibraryMap()
        let (session, document) = try await open(fixture)
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        let child = try #require(document.model.addChild(to: document.model.root.id, text: Self.iPadText,
                                                         undoManager: undo))
        try await Task.sleep(for: .milliseconds(Self.settle))
        #expect(await session.saveNow())
        session.isShowingWelcome = true
        #expect(await session.openAndWait(fixture.url))
        session.didBecomeActive()
        try await Task.sleep(for: .milliseconds(Self.settle))
        #expect(document.model.map.node(withID: child) != nil)
        #expect(undo.canUndo)
        #expect(await document.close())
    }
}
#endif
