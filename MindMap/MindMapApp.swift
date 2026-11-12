import SwiftUI

/// macOS: DocumentGroup (File menu, recents, autosave, versions) with a
/// launch delegate that never shows the open panel. iPadOS: DocumentGroup
/// always starts in its document browser, so each window manages its own
/// document instead (`DocumentWindow`) and lands directly in the editor.
@main
struct MindMapApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { MindMapDocument() }) { file in
            ContentView(model: file.document.model)
        }
        .commands { MindMapCommands() }
        // Attachments open in their own window, keyed by document + attachment.
        WindowGroup("Note", for: AttachmentWindowID.self) { $windowID in
            AttachmentWindow(windowID: windowID)
        }
        .defaultSize(width: 560, height: 640)
        .commandsRemoved()
    }
    #else
    var body: some Scene {
        WindowGroup(id: DocumentWindow.sceneID) {
            DocumentWindow()
        }
        .commands {
            DocumentCommands()
            MindMapCommands()
        }
    }
    #endif
}
