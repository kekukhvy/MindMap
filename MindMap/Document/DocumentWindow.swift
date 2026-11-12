#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// One iPad window: the editor of its `DocumentSession` document plus the
/// Documents menu (New Map, Open…, Rename…). Lands directly in the editor.
struct DocumentWindow: View {
    static let sceneID = "map"

    @State private var session = DocumentSession()
    @SceneStorage("MindMap.documentBookmark") private var sceneBookmark: Data?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var isRenaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(session.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { documentsMenu }
                    if let back = session.backStack.last {
                        // In-window map links (no multi-window support).
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back to “\(back.title)”", systemImage: "chevron.backward") {
                                session.goBackToPreviousMap()
                            }
                            .labelStyle(.titleAndIcon)
                        }
                    }
                }
        }
        .background { SceneSessionReader { session.sceneSession = $0 } }
        .onContinueUserActivity(MapLinkActivity.type) { activity in session.open(activity: activity) }
        .focusedSceneValue(\.documentSession, session)
        .fileImporter(isPresented: $session.isImporting, allowedContentTypes: [.mindMap]) { result in
            if case .success(let url) = result { session.open(url) }
        }
        .alert(session.message ?? "", isPresented: Binding(
            get: { session.message != nil }, set: { if !$0 { session.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
        .alert("Rename Map", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Rename") { session.rename(to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .onOpenURL { url in session.open(url) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: LibraryDebugHook.openRequest)) { note in
            if let url = note.object as? URL { session.open(url) }
        }
        #endif
        .task {
            session.adopt(undoManager)
            session.onOpen = { bookmark in sceneBookmark = bookmark }
            session.start(sceneBookmark: sceneBookmark)
        }
        .onChange(of: undoManager) { _, manager in session.adopt(manager) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.didBecomeActive() } else { session.saveIfNeeded() }
        }
    }

    @ViewBuilder private var content: some View {
        if let document = session.document {
            MapLockGate(model: document.model, title: session.title, documentURL: document.fileURL,
                        save: { [weak document] done in
                            guard let document, document.hasUnsavedChanges else { return done() }
                            document.autosave { _ in done() }
                        }) {
                ContentView(model: document.model, documentURL: document.fileURL,
                            mapOpener: { url, topicID, completion in
                                session.openLinkedMap(url, revealing: topicID, completion: completion)
                            })
            }
            .id(ObjectIdentifier(document))
        } else if session.isWorking {
            ProgressView()
        } else {
            ContentUnavailableView {
                Label("No Map Open", systemImage: "point.3.connected.trianglepath.dotted")
            } actions: {
                Button("New Map") { session.newMap() }
                Button("Open…") { session.isImporting = true }
            }
        }
    }

    private var documentsMenu: some View {
        Menu("Documents", systemImage: "folder") {
            Button("New Map", systemImage: "doc.badge.plus") { session.newMap() }
            Button("Open…", systemImage: "folder") { session.isImporting = true }
            Button("Rename…", systemImage: "pencil") {
                newName = session.title
                isRenaming = true
            }
            .disabled(session.document == nil)
            Divider()
            MapLockMenuItems(model: session.document?.model)
        }
    }
}

/// Reports the UIKit scene session of the window showing it.
private struct SceneSessionReader: UIViewRepresentable {
    let onSession: (UISceneSession?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onSession = onSession
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onSession = onSession
    }

    final class ReaderView: UIView {
        var onSession: ((UISceneSession?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onSession?(window?.windowScene?.session)
        }
    }
}

struct DocumentSessionKey: FocusedValueKey {
    typealias Value = DocumentSession
}

extension FocusedValues {
    var documentSession: DocumentSession? {
        get { self[DocumentSessionKey.self] }
        set { self[DocumentSessionKey.self] = newValue }
    }
}

/// File menu on the iPad menu bar / hardware keyboard: New Map (Cmd+N),
/// New Window (Opt+Cmd+N), Open… (Cmd+O) for the focused window.
struct DocumentCommands: Commands {
    @FocusedValue(\.documentSession) private var session

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Map") { session?.newMap() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(session == nil)
            NewWindowButton()
            Button("Open…") { session?.isImporting = true }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(session == nil)
        }
    }
}

private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") { openWindow(id: DocumentWindow.sceneID) }
            .keyboardShortcut("n", modifiers: [.command, .option])
    }
}
#endif
