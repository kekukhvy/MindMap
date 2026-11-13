import SwiftUI

/// macOS: DocumentGroup (File menu, recents, autosave, versions) with a
/// launch delegate that never shows the open panel. iPadOS: DocumentGroup
/// always starts in its document browser, so each window manages its own
/// document instead (`DocumentWindow`) and lands directly in the editor.
@main
struct MindMapApp: App {
    init() {
        // iCloud map library (WP14): cache bookkeeping + CloudKit sync.
        LibraryService.startAtLaunch()
        #if DEBUG
        WelcomeDebugHook.prepare()
        #endif
    }

    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { MindMapDocument() }) { file in
            MapLockGate(model: file.document.model, title: Self.title(of: file.fileURL), documentURL: file.fileURL) {
                ContentView(model: file.document.model, documentURL: file.fileURL)
            }
            // A revert (the file changed on another device, e.g. iCloud
            // Drive) gives the window a new document and model: rebuild the
            // editor for it instead of keeping the old one in its @State.
            .id(ObjectIdentifier(file.document.model))
            .modifier(MapWindowHooks(url: file.fileURL))
        }
        .commands {
            StorageCommands()
            MindMapCommands()
            LockCommands()
            WelcomeCommands()
            // The standard About panel shows "Version 1.0 (142, 3f3fd45)": the build part
            // carries the commit too.
            CommandGroup(replacing: .appInfo) {
                Button("About MindMap") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [.version: AppVersion.buildDetail])
                }
            }
        }
        // Attachments open in AppKit windows above their map (`AttachmentWindows`);
        // the Welcome window (WP13) is an AppKit window too (`WelcomeWindowController`).

        Settings {
            SettingsView()
        }
    }
    #else
    var body: some Scene {
        WindowGroup(id: DocumentWindow.sceneID) {
            DocumentWindow()
        }
        .commands {
            DocumentCommands()
            MindMapCommands()
            LockCommands()
            WelcomeTourCommands()
        }
    }
    #endif

    /// Name shown on the lock screen / in prompts (file name, not content).
    static func title(of url: URL?) -> String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }
}
