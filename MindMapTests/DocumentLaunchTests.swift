import Foundation
import Testing
@testable import MindMap

struct UntitledNameTests {
    @Test func firstFreeName() {
        #expect(UntitledName.next(existing: [], pathExtension: "mindmap") == "Untitled.mindmap")
        #expect(UntitledName.next(existing: ["Untitled.mindmap"], pathExtension: "mindmap") == "Untitled 2.mindmap")
        #expect(UntitledName.next(existing: ["Untitled.mindmap", "Untitled 2.mindmap", "Untitled 4.mindmap"],
                                  pathExtension: "mindmap") == "Untitled 3.mindmap")
    }

    @Test func caseInsensitiveAndOtherExtensionsIgnored() {
        #expect(UntitledName.next(existing: ["untitled.MINDMAP"], pathExtension: "mindmap") == "Untitled 2.mindmap")
        #expect(UntitledName.next(existing: ["Untitled.txt", "Untitled"], pathExtension: "mindmap")
                == "Untitled.mindmap")
    }

    @Test func iCloudPlaceholdersCount() {
        #expect(UntitledName.next(existing: [".Untitled.mindmap.icloud"], pathExtension: "mindmap")
                == "Untitled 2.mindmap")
    }
}

/// Bookmark coder backed by a dictionary (no file system).
final class FakeBookmarkCoder: BookmarkCoding {
    var stale = false
    var broken = false
    private(set) var created = 0

    func bookmark(for url: URL) throws -> Data {
        created += 1
        return Data(url.path.utf8)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if broken { throw CocoaError(.fileReadCorruptFile) }
        return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale)
    }
}

struct LastDocumentStoreTests {
    private let root = URL(fileURLWithPath: "/container/Documents")
    private let otherRoot = URL(fileURLWithPath: "/new-container/Documents")

    private func makeStore(_ coder: FakeBookmarkCoder, existing: Set<String>) -> LastDocumentStore {
        let defaults = UserDefaults(suiteName: "LastDocumentStoreTests.\(UUID().uuidString)")!
        return LastDocumentStore(defaults: defaults, coder: coder, exists: { existing.contains($0.path) })
    }

    @Test func emptyStoreResolvesNothing() {
        let store = makeStore(FakeBookmarkCoder(), existing: [])
        #expect(store.resolve(roots: [root]) == nil)
    }

    @Test func resolvesBookmark() {
        let url = root.appendingPathComponent("Plan.mindmap")
        let store = makeStore(FakeBookmarkCoder(), existing: [url.path])
        store.remember(url, roots: [root])
        #expect(store.resolve(roots: [root])?.path == url.path)
    }

    @Test func staleBookmarkIsRefreshed() {
        let url = root.appendingPathComponent("Plan.mindmap")
        let coder = FakeBookmarkCoder()
        let store = makeStore(coder, existing: [url.path])
        store.remember(url, roots: [root])
        coder.stale = true
        #expect(store.resolve(roots: [root])?.path == url.path)
        #expect(coder.created == 2)
    }

    @Test func brokenBookmarkFallsBackToRelativePathInNewContainer() {
        let old = root.appendingPathComponent("Work/Plan.mindmap")
        let moved = otherRoot.appendingPathComponent("Work/Plan.mindmap")
        let coder = FakeBookmarkCoder()
        let store = makeStore(coder, existing: [moved.path])
        store.remember(old, roots: [root])
        coder.broken = true
        #expect(store.resolve(roots: [otherRoot])?.path == moved.path)
        // The entry was rewritten for the new location.
        coder.broken = false
        #expect(store.resolve(roots: [otherRoot])?.path == moved.path)
    }

    @Test func missingDocumentIsForgotten() {
        let url = root.appendingPathComponent("Gone.mindmap")
        var existing: Set<String> = [url.path]
        let defaults = UserDefaults(suiteName: "LastDocumentStoreTests.\(UUID().uuidString)")!
        var store = LastDocumentStore(defaults: defaults, coder: FakeBookmarkCoder(), exists: { existing.contains($0.path) })
        store.remember(url, roots: [root])
        existing = []
        store.exists = { existing.contains($0.path) }
        #expect(store.resolve(roots: [root]) == nil)
        #expect(defaults.dictionary(forKey: store.key) == nil)
    }

    @Test func documentOutsideOwnFoldersHasNoRelativePath() {
        let picked = URL(fileURLWithPath: "/iCloud/Shared/Plan.mindmap")
        #expect(LastDocumentStore.relativePath(of: picked, in: [root]) == nil)
        #expect(LastDocumentStore.relativePath(of: root.appendingPathComponent("a/b.mindmap"), in: [root]) == "a/b.mindmap")
        #expect(LastDocumentStore.relativePath(of: root, in: [root]) == nil)
    }
}

struct LaunchReopenTests {
    @Test func skipsOpenDuplicatesAndLimits() {
        let a = URL(fileURLWithPath: "/d/a.mindmap"), b = URL(fileURLWithPath: "/d/b.mindmap")
        let c = URL(fileURLWithPath: "/d/c.mindmap"), d = URL(fileURLWithPath: "/d/d.mindmap")
        let e = URL(fileURLWithPath: "/d/e.mindmap")
        #expect(LaunchEnvironment.reopenCandidates(recents: [a, b, a, c, d, e], alreadyOpen: [b]) == [a, c, d])
        #expect(LaunchEnvironment.reopenCandidates(recents: [], alreadyOpen: []).isEmpty)
        #expect(LaunchEnvironment.isTesting)
    }
}

#if os(iOS)
import UIKit

@MainActor
struct MindMapUIDocumentTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UIDocTest-\(UUID().uuidString).mindmap")
    }

    @Test func undoManagerChangesMarkDirtyAndSaveRoundTrips() async throws {
        let url = tempURL()
        let document = MindMapUIDocument(fileURL: url)
        #expect(await document.save(to: url, for: .forCreating))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        #expect(!document.hasUnsavedChanges)
        let child = try #require(document.model.addChild(to: document.model.root.id, text: "Saved", undoManager: undo))
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.hasUnsavedChanges)
        #expect(await document.close())

        let reopened = MindMapUIDocument(fileURL: url)
        #expect(await reopened.open())
        #expect(reopened.model.map.node(withID: child)?.text == "Saved")
        #expect(await reopened.close())
        try? FileManager.default.removeItem(at: url)
    }

    /// The test host's own window: lands in an editor (no browser), its
    /// document adopts the window undo manager that the editor uses.
    @Test func launchWindowOpensEditorWithWindowUndoManager() async throws {
        var session: DocumentSession?
        for _ in 0..<50 {
            session = DocumentSession.debugInstances.compactMap(\.session).first { $0.document != nil }
            if session != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let document = try #require(session?.document)
        #expect(document.fileURL.lastPathComponent.hasPrefix("Untitled"))
        let editor = try #require(EditorController.debugInstances.compactMap(\.editor)
            .first { $0.model === document.model })
        let undo = try #require(editor.undoManager)
        #expect(document.undoManager === undo)
    }
}
#endif
