#if DEBUG && os(macOS)
import AppKit
import Foundation

/// DEBUG-only: `MINDMAP_DEBUG_FOCUS=1` replays human input on an open map
/// whose root is "FocusProbe" (window title contains "focus-probe"): mouse
/// and key events go through the app's event queue like real hardware
/// input. Scenarios: double-click a topic, select + Tab, select + Return,
/// double-click while another window is key; each types a name and
/// commits it. Writes the responder/editor state per step and the
/// resulting names to `<container tmp>/focus-report.txt`.
@MainActor
enum DebugFocusProbe {
    private static var log: [String] = []

    static func run(_ editor: EditorController) {
        guard !LaunchEnvironment.isTesting, editor.model.root.text == "FocusProbe" else { return }
        if let mode = ProcessInfo.processInfo.environment["MINDMAP_DEBUG_NOTEWINDOW"] {
            Task { @MainActor in await noteWindowScenario(editor, fullScreen: mode == "fullscreen") }
            return
        }
        guard ProcessInfo.processInfo.environment["MINDMAP_DEBUG_FOCUS"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(500))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("focus-probe") }) else {
                return
            }
            window.makeKeyAndOrderFront(nil)
            await scenarios(editor, window)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("focus-report.txt")
            try? log.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// `MINDMAP_DEBUG_NOTEWINDOW=fullscreen|normal`: (full screen map window,)
    /// Add Note on the first topic, type "a", Return, "b" with real queued
    /// key events (the menu's plain-key Return must not add a topic), then
    /// report every visible window's frame, style, space and parent to
    /// `<container tmp>/note-window-report.txt` + `note-window.png`, delete
    /// the note, close it via Esc and quit.
    private static func noteWindowScenario(_ editor: EditorController, fullScreen: Bool) async {
        try? await Task.sleep(for: .seconds(2))
        NSApp.activate(ignoringOtherApps: true)
        guard let window = editor.hostWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.title.contains("focus-probe") }),
              let topic = editor.model.root.children.first?.id else { return }
        window.makeKeyAndOrderFront(nil)
        var preface = "active=\(NSApp.isActive)"
        if fullScreen {
            window.toggleFullScreen(nil)
            for _ in 0..<30 where !window.styleMask.contains(.fullScreen) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1))
            preface += " fullScreenAfterToggle=\(window.styleMask.contains(.fullScreen))"
        }
        let topicCount = editor.model.map.root.subtreeCount
        editor.addNote(to: topic)
        try? await Task.sleep(for: .seconds(2))
        var lines = [preface, "map fullScreen=\(window.styleMask.contains(.fullScreen)) screen=\(window.screen?.frame ?? .zero)"
                     + " onActiveSpace=\(window.isOnActiveSpace)"]
        let note = AttachmentWindows.shared.openWindows.first
        if let note {
            note.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            for (char, code) in [("a", UInt16(0)), ("\r", 36), ("b", 11)] {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: note.windowNumber, context: nil, characters: char,
                                                    charactersIgnoringModifiers: char, isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            try? await Task.sleep(for: .milliseconds(800))
            let id = note.windowID.attachmentID
            lines.append("typed note text=\(String(reflecting: MarkdownNote.text(editor.model.content(of: id)))) "
                         + "inMap=\(!editor.model.isDraft(id) && editor.model.attachment(id) != nil) "
                         + "topicsBefore=\(topicCount) topicsAfter=\(editor.model.map.root.subtreeCount) "
                         + "keyWindowIsNote=\(NSApp.keyWindow === note)")
        }
        for item in NSApp.windows where item.isVisible {
            let mask = item.styleMask
            lines.append("window \"\(item.title)\" frame=\(item.frame) titled=\(mask.contains(.titled)) "
                         + "closable=\(mask.contains(.closable)) resizable=\(mask.contains(.resizable)) "
                         + "fullScreen=\(mask.contains(.fullScreen)) zoomed=\(item.isZoomed) "
                         + "onActiveSpace=\(item.isOnActiveSpace) parentIsMap=\(item.parent === window) "
                         + "closeButton=\(item.standardWindowButton(.closeButton)?.isHidden == false) "
                         + "tabs=\(item.tabbedWindows?.count ?? 0) behavior=\(item.collectionBehavior.rawValue)")
        }
        if let note {
            // Whole window incl. title bar / toolbar, drawn in-process.
            if let frameView = note.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-window.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            // Clicking the map keeps the note above it.
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(400))
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let numbers = list.compactMap { $0[kCGWindowNumber as String] as? Int }
            lines.append("after map front: noteOnScreenIndex=\(numbers.firstIndex(of: note.windowNumber) ?? -1) "
                         + "mapOnScreenIndex=\(numbers.firstIndex(of: window.windowNumber) ?? -1)")
            // Leave the probe map unchanged: delete the note, then Esc.
            editor.model.deleteAttachment(note.windowID.attachmentID, undoManager: editor.undoManager)
            note.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: note.windowNumber, context: nil, characters: "\u{1b}",
                                             charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
                if let event { NSApp.postEvent(event, atStart: false) }
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .seconds(1))
            lines.append("after Esc: note visible=\(note.isVisible)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-window-report.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if fullScreen, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            try? await Task.sleep(for: .seconds(2))
        }
        editor.undoManager?.removeAllActions()
        (window.windowController?.document as? NSDocument)?.updateChangeCount(.changeCleared)
        NSApp.terminate(nil)
    }

    private static func scenarios(_ editor: EditorController, _ window: NSWindow) async {
        let topics = editor.model.root.children.map(\.id)
        guard topics.count >= 2 else { return }
        // 1. Double-click = new child, typed immediately.
        await click(editor, window, topics[0], count: 2)
        note(editor, "double-click")
        await type("abc", window)
        await key("\r", 36, window)
        log.append("RESULT double-click child: \(lastChildText(editor, topics[0]))")
        // 2. Select + Tab.
        await click(editor, window, topics[1], count: 1)
        await key("\t", 48, window)
        note(editor, "select+Tab")
        await type("tab", window)
        await key("\r", 36, window)
        log.append("RESULT Tab child: \(lastChildText(editor, topics[1]))")
        // 3. Return on the new (selected) child = sibling.
        await key("\r", 36, window)
        note(editor, "Return")
        await type("ret", window)
        await key("\r", 36, window)
        log.append("RESULT Return sibling: \(lastChildText(editor, topics[1]))")
        // 4. Another window is key, then the map window is double-clicked.
        let other = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 300, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        await click(editor, window, topics[0], count: 2)
        note(editor, "double-click from other window")
        await type("win", window)
        await key("\r", 36, window)
        log.append("RESULT other-window double-click: \(lastChildText(editor, topics[0]))")
        other.close()
    }

    private static func lastChildText(_ editor: EditorController, _ id: UUID) -> String {
        editor.model.map.node(withID: id)?.children.last?.text ?? "nil"
    }

    private static func note(_ editor: EditorController, _ step: String) {
        let window = NSApp.keyWindow
        let responder = window?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"
        log.append("\(step): key=\(window?.title ?? "nil") responder=\(responder) "
                   + "editing=\(editor.editingID != nil) draft=\(editor.draftText) focusLog=\(NodeEditorField.debugFocusLog)")
    }

    private static func click(_ editor: EditorController, _ window: NSWindow, _ id: UUID, count: Int) async {
        guard let frame = editor.scene.layout.frames[id] else { return }
        let screen = editor.viewport.toScreen(frame)
        let point = CGPoint(x: screen.midX, y: editor.viewSize.height - screen.midY)
        for clicks in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0)
                if let event { NSApp.postEvent(event, atStart: false) }
                try? await Task.sleep(for: .milliseconds(90))
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static func type(_ text: String, _ window: NSWindow) async {
        for character in text { await key(String(character), 0, window) }
    }

    private static func key(_ characters: String, _ code: UInt16, _ window: NSWindow) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: code)
            if let event { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(80))
    }
}
#endif
