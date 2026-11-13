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

    private func segmentedControl(in view: NSView?) -> NSSegmentedControl? {
        guard let view else { return nil }
        if let found = view as? NSSegmentedControl { return found }
        for sub in view.subviews {
            if let found = segmentedControl(in: sub) { return found }
        }
        return nil
    }

    @Test func clickingNoteIconOpensPreviewThenEditableWindow() async throws {
        var topic = Node(text: "Topic with note")
        let note = Attachment(kind: .markdown, title: "Meeting")
        let plain = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        topic.attachments = [note]
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        let harness = try await CanvasEventHarness(realDocumentWith: plain)
        var closed = false
        defer { if !closed { harness.close() } }
        let model = harness.editor.model
        let original = "# Topic with note\n\nhello"
        // Content first (topics show icons only for non-empty notes), as when a file loads.
        model.attachmentStore.write(MarkdownNote.data(original), to: note.fileName)
        model.debugReplaceMap(map)
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
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0.title == "Meeting"
            }
        }
        let window = try #require(noteWindow)
        // A note with text opens in Preview: no text view until Edit is picked.
        try await harness.wait(300)
        #expect(textView(in: window.contentView) == nil)
        let mode = try #require(segmentedControl(in: window.contentView?.superview))
        mode.selectedSegment = 0
        mode.sendAction(mode.action, to: mode.target)
        var editing: NoteTextView?
        for _ in 0..<30 where editing == nil {
            try await harness.wait(100)
            editing = textView(in: window.contentView)
        }
        let editorView = try #require(editing)
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

    private func openNote(_ harness: CanvasEventHarness, on topic: UUID) async throws -> NSWindow {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        harness.editor.addNote(to: topic)
        for _ in 0..<30 {
            try await harness.wait(100)
            if let window = NSApp.windows.first(where: {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && textView(in: $0.contentView) != nil
            }) {
                try await harness.wait(600)
                return window
            }
        }
        throw CancellationError()
    }

    private func pressEscape(in window: NSWindow) async throws {
        // Delivered straight to the window (the inactive test host cannot
        // make it key).
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func toolbarLabels(_ window: NSWindow) -> [String] {
        (window.toolbar?.items ?? []).map(\.label)
    }

    /// A new note opens as a normal floating window above its map (child
    /// window, never a tab / full screen): window controls, resizable with
    /// a minimum, default ~640x720, Done (Esc) + Delete in the toolbar; the
    /// next note opens with the remembered frame. Closed empty, the new
    /// note is gone without an undo step.
    @Test func noteWindowIsNormalResizableAndClosable() async throws {
        let topic = Node(text: "Topic")
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        let key = AttachmentWindowChrome.frameKey(for: .markdown)
        let savedBefore = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.set(savedBefore, forKey: key) }
        let harness = try await CanvasEventHarness(realDocumentWith: map)
        defer { harness.close() }
        let model = harness.editor.model

        let window = try await openNote(harness, on: topic.id)
        let mask = window.styleMask
        #expect(mask.contains(.titled) && mask.contains(.closable) && mask.contains(.miniaturizable)
                && mask.contains(.resizable) && !mask.contains(.fullScreen))
        #expect(window.tabbingMode == .disallowed && (window.tabbedWindows?.count ?? 0) <= 1)
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.parent === harness.window)
        #expect(!window.isZoomed)
        #expect(abs(window.frame.width - 640) < 2 && abs(window.frame.height - 720) < 60)
        #expect(window.contentMinSize == AttachmentWindowChrome.minSize)
        let visible = try #require(window.screen?.visibleFrame)
        #expect(visible.contains(window.frame))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
        // Done (label-less bridged item, identified by its tooltip) + Delete Note.
        #expect(window.toolbar?.items.contains { $0.toolTip == "Close this window (Esc)" } == true)
        #expect(toolbarLabels(window).contains("Delete Note"))
        // The editor fills the window (no inset page).
        let text = try #require(textView(in: window.contentView))
        let scroll = try #require(text.enclosingScrollView)
        let scrollFrame = scroll.convert(scroll.bounds, to: nil)
        let content = try #require(window.contentView).bounds
        #expect(abs(scrollFrame.width - content.width) < 2)
        #expect(scrollFrame.minY < 2)
        // Empty new note: a draft, no topic icon, no undo step.
        let noteID = try #require(model.drafts(of: topic.id).first?.id)
        #expect(harness.editor.scene.nodes[topic.id]?.attachments.isEmpty == true)
        let documentUndo = try #require(text.documentUndoManager)
        let undoCount = documentUndo.canUndo

        // User resizes it; Esc in the text closes it; the next note reuses the frame.
        let resized = CGRect(x: visible.minX + 40, y: visible.minY + 30, width: 700, height: 600)
        window.setFrame(resized, display: true)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        window.makeFirstResponder(text)
        try await harness.wait(200)
        try await pressEscape(in: window)
        try await harness.wait(800)
        #expect(!window.isVisible)
        #expect(model.attachment(noteID) == nil)
        #expect(model.map.node(withID: topic.id)?.attachments.isEmpty == true)
        #expect(documentUndo.canUndo == undoCount)
        let second = try await openNote(harness, on: topic.id)
        #expect(second.frame == resized)
        second.close()
        try await harness.wait(300)
        #expect(model.map.node(withID: topic.id)?.attachments.isEmpty == true)
    }

    /// Window lifetime: a note window over a plain (unpatched) document
    /// window is opened / closed several times with autorelease drains and
    /// finally left open while its map closes; it floats above the map
    /// (child window, window-server z-order) the whole time. The FULL-SCREEN
    /// map case runs in the real app (`DebugFocusProbe`,
    /// `MINDMAP_DEBUG_NOTEWINDOW=fullscreen`): toggling full screen inside
    /// the inactive test host breaks the other event tests' key-window patch.
    @Test func noteWindowsOpenAndCloseRepeatedlyAboveTheirMap() async throws {
        let key = AttachmentWindowChrome.frameKey(for: .markdown)
        let savedBefore = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.set(savedBefore, forKey: key) }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSDocumentController.shared.newDocument(nil)
        try await Task.sleep(for: .milliseconds(800))
        let mapWindow = try #require(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible
            && $0.contentView != nil && $0.frame.width > 300 })
        let editor = try #require(EditorController.debugInstances.compactMap(\.editor).last)
        let topic = Node(text: "Topic")
        editor.model.debugReplaceMap(MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic])))
        mapWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let screen = try #require(mapWindow.screen)

        for round in 0..<3 {
            let opened = Set(NSApp.windows.map(ObjectIdentifier.init))
            editor.addNote(to: topic.id)
            var found: NSWindow?
            for _ in 0..<30 where found == nil {
                try await Task.sleep(for: .milliseconds(100))
                found = NSApp.windows.first {
                    !opened.contains(ObjectIdentifier($0)) && $0.isVisible && textView(in: $0.contentView) != nil
                }
            }
            let window = try #require(found)
            try await Task.sleep(for: .milliseconds(800))
            #expect(!window.styleMask.contains(.fullScreen))
            #expect(window.isVisible)
            #expect(window.parent === mapWindow)
            #expect(window.isOnActiveSpace == mapWindow.isOnActiveSpace)
            #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
            #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
            #expect(window.styleMask.contains(.resizable))
            // A normal-sized window on the map's screen, above the map.
            #expect(abs(window.frame.width - 640) < 2)
            #expect(window.frame.width < screen.frame.width * 0.9 && window.frame.height < screen.frame.height)
            #expect(screen.frame.contains(window.frame))
            // Window-server order (front to back): the note is above its map.
            let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let numbers = all.compactMap { $0[kCGWindowNumber as String] as? Int }
            let noteIndex = numbers.firstIndex(of: window.windowNumber) ?? Int.max
            let mapIndex = numbers.firstIndex(of: mapWindow.windowNumber) ?? -1
            // (Only meaningful while the test windows' space is the active one:
            // another app's full-screen space may be in front during test runs.)
            if mapWindow.isOnActiveSpace {
                #expect(noteIndex < mapIndex, "round \(round): note \(noteIndex) map \(mapIndex)")
            }
            if round == 0 {
                // Snapshot of the whole note window (title bar + toolbar + editor).
                if let frameView = window.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-window-test.png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                // The map becoming key / front again keeps the note above it.
                mapWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(300))
                #expect(window.isVisible && window.parent === mapWindow)
            }
            autoreleasepool { window.performClose(nil) }
            try await Task.sleep(for: .milliseconds(400))
            #expect(!window.isVisible)
            #expect(AttachmentWindows.shared.openWindows.isEmpty)
            #expect(editor.model.map.node(withID: topic.id)?.attachments.isEmpty == true)
        }

        // A note open while the map closes goes away with it.
        editor.addNote(to: topic.id)
        try await Task.sleep(for: .milliseconds(800))
        #expect(AttachmentWindows.shared.openWindows.count == 1)
        editor.model.debugReplaceMap(MindMap())
        mapWindow.close()
        try await Task.sleep(for: .milliseconds(800))
        #expect(AttachmentWindows.shared.openWindows.isEmpty)
    }

    /// Typing makes the note real (one "Add Note" step, icon on the topic);
    /// emptying it again and closing deletes it as an undoable "Delete Note".
    @Test func emptiedNoteIsDeletedWhenItsWindowCloses() async throws {
        let topic = Node(text: "Topic")
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        let harness = try await CanvasEventHarness(realDocumentWith: map)
        defer { harness.close() }
        let model = harness.editor.model

        let window = try await openNote(harness, on: topic.id)
        let text = try #require(textView(in: window.contentView))
        let documentUndo = try #require(text.documentUndoManager)
        text.insertText("Idea", replacementRange: NSRange(location: 0, length: 0))
        try await harness.wait(300)
        for _ in 0..<30 where model.map.node(withID: topic.id)?.attachments.isEmpty != false {
            try await harness.wait(100)
        }
        let note = try #require(model.map.node(withID: topic.id)?.attachments.first)
        #expect(MarkdownNote.text(model.content(of: note.id)) == "Idea")
        #expect(documentUndo.undoActionName == "Add Note")
        #expect(harness.editor.scene.nodes[topic.id]?.attachments.count == 1)

        text.selectAll(nil)
        text.insertText("", replacementRange: text.selectedRange())
        try await harness.wait(300)
        window.performClose(nil)
        try await harness.wait(500)
        #expect(!window.isVisible)
        #expect(model.attachment(note.id) == nil)
        #expect(documentUndo.undoActionName == "Delete Note")
        // (Undo of it: model tests; the test host never closes the event undo group.)
        documentUndo.removeAllActions()
        NSDocumentController.shared.documents.first { $0.undoManager === documentUndo }?
            .updateChangeCount(.changeCleared)
    }
}
#endif
