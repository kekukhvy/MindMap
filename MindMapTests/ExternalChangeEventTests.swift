#if os(macOS)
import AppKit
import Testing
@testable import MindMap

/// Real-document test: the map file is changed by another device (iCloud
/// Drive) while it is open on the Mac. AppKit then reverts the clean document
/// to the file's contents, which gives the window a new `MindMapDocument`
/// and model; the open map must keep working without being reopened.
@MainActor
@Suite(.serialized)
struct ExternalChangeEventTests {
    private static let originalText = "Topic"
    private static let otherDeviceText = "Changed on iPad"
    private static let macText = "Edited on Mac"
    private static let settle = 800
    private static let poll = 100
    /// Seconds AppKit gets to notice the change (about 0.5 s observed).
    private static let revertTimeout: TimeInterval = 5

    private func textView(in view: NSView?) -> NoteTextView? {
        guard let view else { return nil }
        if let found = view as? NoteTextView { return found }
        for sub in view.subviews {
            if let found = textView(in: sub) { return found }
        }
        return nil
    }

    /// Adds a note to `topic` and returns its new window (nil: none opened).
    private func openNote(_ editor: EditorController, on topic: UUID) async throws -> NSWindow? {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        editor.addNote(to: topic)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if let window = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && $0.isVisible }) {
                try await Task.sleep(for: .milliseconds(600))
                return window
            }
        }
        return nil
    }

    private func map(topic: UUID, text: String) -> MindMap {
        MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [Node(id: topic, text: text)]))
    }

    /// The editor of the document window showing `url` (the latest one).
    private func liveEditor(for url: URL) -> EditorController? {
        let key = LaunchEnvironment.key(url)
        return EditorController.debugInstances.compactMap(\.editor).last {
            $0.documentURL.map(LaunchEnvironment.key) == key && $0.hostWindow != nil
        }
    }

    /// Polls `condition` until it holds or `revertTimeout` passes.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.revertTimeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(Self.poll))
        }
        return true
    }

    @Test func openMapKeepsWorkingAfterItsFileChangedOnAnotherDevice() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExternalChange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Shared.mindmap")
        let topic = UUID()
        try MapLinkTests.writeMap(map(topic: topic, text: Self.originalText), to: url)

        // Opened like File > Open (no `CanvasEventHarness`: its key-window
        // class patch breaks KVO when the window's toolbar is rebuilt).
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        try await Task.sleep(for: .milliseconds(Self.settle))
        let document = try #require(MapTabOpener.document(for: url))
        defer { document.close() }
        let editorBefore = try #require(liveEditor(for: url))
        let noteBefore = try #require(try await openNote(editorBefore, on: topic))
        #expect(textView(in: noteBefore.contentView) != nil)

        // Another device saves the map: a coordinated write, as iCloud Drive
        // does. AppKit (file presenter) reverts the clean document by itself.
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do { try MapLinkTests.writeMap(map(topic: topic, text: Self.otherDeviceText), to: target) } catch {
                writeError = error
            }
        }
        #expect(coordinationError == nil && writeError == nil)
        let reverted = await waitUntil {
            liveEditor(for: url)?.model.map.node(withID: topic)?.text == Self.otherDeviceText
        }
        try await Task.sleep(for: .milliseconds(Self.settle))

        // The map shows the new content.
        #expect(reverted)
        let editor = try #require(liveEditor(for: url))
        #expect(editor.model.map.node(withID: topic)?.text == Self.otherDeviceText)
        #expect(editor.scene.nodes[topic]?.text == Self.otherDeviceText)
        // The note window of the replaced content closed with it.
        #expect(!noteBefore.isVisible)

        // A note opened after the change edits the live document.
        let noteAfter = try #require(try await openNote(editor, on: topic))
        defer { noteAfter.close() }
        #expect(textView(in: noteAfter.contentView) != nil)

        // An edit on the Mac after the change is what the document saves.
        #expect(editor.model.rename(topic, to: Self.macText, undoManager: editor.undoManager))
        let copy = folder.appendingPathComponent("Saved.mindmap")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: copy, ofType: document.fileType ?? "", for: .saveToOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #expect(try MapFiles.readMap(at: copy).node(withID: topic)?.text == Self.macText)
        editor.undoManager?.removeAllActions()
        document.updateChangeCount(.changeCleared)
    }
}
#endif
