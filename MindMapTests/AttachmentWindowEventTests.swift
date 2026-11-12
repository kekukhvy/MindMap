#if os(macOS)
import AppKit
import Testing
@testable import MindMap

/// Real-event test (see `CanvasEventHarness`): clicking a topic's note icon
/// in a real document window opens the note window, which edits the same
/// document (store + the document's undo manager) and closes with the map.
@MainActor
@Suite(.serialized)
struct AttachmentWindowEventTests {
    private func textView(in view: NSView?) -> NoteTextView? {
        guard let view else { return nil }
        if let found = view as? NoteTextView { return found }
        for sub in view.subviews {
            if let found = textView(in: sub) { return found }
        }
        return nil
    }

    @Test func clickingNoteIconOpensEditableWindow() async throws {
        var topic = Node(text: "Topic with note")
        let note = Attachment(kind: .markdown, title: "Meeting")
        topic.attachments = [note]
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        let harness = try await CanvasEventHarness(realDocumentWith: map)
        var closed = false
        defer { if !closed { harness.close() } }
        let model = harness.editor.model
        let original = "# Topic with note\n\nhello"
        model.attachmentStore.write(MarkdownNote.data(original), to: note.fileName)
        try await harness.wait(300)

        let frame = harness.screenFrame(of: topic.id)
        let info = try #require(harness.editor.scene.nodes[topic.id])
        let scale = harness.editor.viewport.scale
        let icon = AttachmentIconRow.iconSize(fontSize: info.appearance.fontSize) * scale
        let point = CGPoint(x: frame.maxX - info.appearance.paddingH * scale - icon / 2, y: frame.midY)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        try await harness.click(point)
        var noteWindow: NSWindow?
        for _ in 0..<30 where noteWindow == nil {
            try await harness.wait(100)
            noteWindow = NSApp.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && textView(in: $0.contentView) != nil
            }
        }
        let window = try #require(noteWindow)
        let editorView = try #require(textView(in: window.contentView))
        #expect(harness.editor.selectedID == topic.id)
        #expect(editorView.string == original)
        #expect(window.title == "Meeting")

        // Typing writes through to the document's store as an undo step.
        let end = (editorView.string as NSString).length
        editorView.insertText(" world", replacementRange: NSRange(location: end, length: 0))
        try await harness.wait(300)
        #expect(MarkdownNote.text(model.content(of: note.id)) == original + " world")
        let documentUndo = try #require(editorView.documentUndoManager)
        #expect(documentUndo.canUndo)
        let document = NSDocumentController.shared.documents.first { $0.undoManager === documentUndo }
        // It is the map document's own undo manager (= what marks the
        // SwiftUI document dirty when the event's undo group closes).
        #expect(document != nil)
        #expect(documentUndo.undoActionName == "Edit Note")

        // Cmd+Z in the note window (NoteTextView.undo) reverts the edit.
        editorView.undo(nil)
        try await harness.wait(300)
        #expect(MarkdownNote.text(model.content(of: note.id)) == original)
        #expect(editorView.string == original)

        documentUndo.removeAllActions()
        document?.updateChangeCount(.changeCleared)
        // Closing the map closes its note windows.
        harness.close()
        closed = true
        try await harness.wait(800)
        #expect(!window.isVisible)
    }

    /// A new note opens as a normal window (not a tab / full screen): window
    /// controls, resizable with a minimum, default ~640x720, Done + Esc
    /// close it, and the next note opens with the remembered frame.
    @Test func noteWindowIsNormalResizableAndClosable() async throws {
        let topic = Node(text: "Topic")
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        let key = AttachmentWindowChrome.frameKey(for: .markdown)
        let savedBefore = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.set(savedBefore, forKey: key) }
        let harness = try await CanvasEventHarness(realDocumentWith: map)
        defer { harness.close() }

        func openNote() async throws -> NSWindow {
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            harness.editor.addNote(to: topic.id)
            for _ in 0..<30 {
                try await harness.wait(100)
                if let window = NSApp.windows.first(where: {
                    !before.contains(ObjectIdentifier($0)) && $0.isVisible && textView(in: $0.contentView) != nil
                }) {
                    try await harness.wait(900)
                    return window
                }
            }
            throw CancellationError()
        }

        let window = try await openNote()
        let mask = window.styleMask
        #expect(mask.contains(.titled) && mask.contains(.closable) && mask.contains(.miniaturizable)
                && mask.contains(.resizable) && !mask.contains(.fullScreen))
        #expect(window.tabbingMode == .disallowed && (window.tabbedWindows?.count ?? 0) <= 1)
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.isZoomed)
        #expect(abs(window.frame.width - 640) < 2 && abs(window.frame.height - 720) < 60)
        #expect(window.contentMinSize == AttachmentWindowChrome.minSize)
        let visible = try #require(window.screen?.visibleFrame)
        #expect(visible.contains(window.frame))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)

        // User resizes it; Esc in the text closes it; the next note reuses the frame.
        let resized = CGRect(x: visible.minX + 40, y: visible.minY + 30, width: 700, height: 600)
        window.setFrame(resized, display: true)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        // Delivered straight to the window (the inactive test host cannot
        // make it key; patching its class breaks SwiftUI's toolbar KVO).
        let text = try #require(textView(in: window.contentView))
        window.makeFirstResponder(text)
        try await harness.wait(200)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            window.sendEvent(event)
            try await harness.wait(50)
        }
        try await harness.wait(800)
        #expect(!window.isVisible)
        let second = try await openNote()
        #expect(second.frame == resized)
        second.close()
    }
}
#endif
