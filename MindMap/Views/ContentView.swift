import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Editor window/scene for one document: canvas + toolbar + menu wiring.
struct ContentView: View {
    let model: MindMapModel
    /// The document's file (nil while never saved).
    var documentURL: URL?
    /// Opens linked maps; nil = platform default (macOS: new tab).
    var mapOpener: MapOpener?
    @State private var editor: EditorController
    @Environment(\.undoManager) private var undoManager
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    init(model: MindMapModel, documentURL: URL? = nil, mapOpener: MapOpener? = nil) {
        self.model = model
        self.documentURL = documentURL
        self.mapOpener = mapOpener
        _editor = State(initialValue: EditorController(model: model))
    }

    #if os(iOS)
    /// Handwriting opens full screen, other attachments in a page sheet.
    private func presentedAttachment(fullScreen: Bool) -> Binding<AttachmentRequest?> {
        Binding(get: { editor.presentedAttachment.flatMap { $0.fullScreen == fullScreen ? $0 : nil } },
                set: { editor.presentedAttachment = $0 })
    }
    #endif

    var body: some View {
        CanvasView(editor: editor)
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar { FormatToolbar(editor: editor) }
            #if os(iOS)
            .toolbarRole(.editor)
            .overlay(alignment: .bottomLeading) { OutlineCornerButton(editor: editor) }
            #endif
            .focusedSceneValue(\.mindMapEditor, editor)
            .sheet(item: $editor.colorSheet) { request in
                ColorPickerSheet(request: request) { hex in editor.applyColorSheet(request, hex: hex) }
            }
            .sheet(item: $editor.linkEditor) { request in
                LinkEditorSheet(editor: editor, nodeID: request.nodeID, initialMode: request.mode)
            }
            .alert("Open Map", isPresented: Binding(get: { editor.mapLinkProblem != nil },
                                                   set: { if !$0 { editor.mapLinkProblem = nil } }),
                   presenting: editor.mapLinkProblem) { problem in
                Button("Locate…") {
                    // After the alert is gone (one presentation at a time).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editor.beginLocateMap(problem.nodeID) }
                }
                Button("Remove Link", role: .destructive) { editor.removeLink(problem.nodeID) }
                Button("Cancel", role: .cancel) {}
            } message: { problem in
                Text(problem.message)
            }
            .background {
                // "Locate…" picker on its own view (one file dialog per view).
                Color.clear.fileImporter(isPresented: $editor.isMapLocatorPresented,
                                         allowedContentTypes: [.mindMap]) { result in editor.finishLocateMap(result) }
            }
            .onChange(of: documentURL, initial: true) { _, url in editor.documentURL = url }
            .onChange(of: MapRevealCenter.shared.pending(for: editor.documentURL), initial: true) { _, request in
                guard request != nil, let url = editor.documentURL,
                      let topicID = MapRevealCenter.shared.take(for: url) else { return }
                editor.revealRequestedTopic(topicID)
            }
            #if os(macOS)
            .background { HostWindowReader { window in editor.hostWindow = window } }
            #endif
            .alert("Go to", isPresented: Binding(get: { editor.linkMessage != nil },
                                                set: { if !$0 { editor.linkMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editor.linkMessage ?? "")
            }
            #if os(iOS)
            .sheet(item: presentedAttachment(fullScreen: false)) { request in
                AttachmentSheet(model: model, attachmentID: request.attachmentID, undoManager: undoManager)
            }
            .fullScreenCover(item: presentedAttachment(fullScreen: true)) { request in
                AttachmentSheet(model: model, attachmentID: request.attachmentID, undoManager: undoManager,
                                fullScreen: true)
            }
            #else
            .onChange(of: editor.presentedAttachment) { _, request in
                guard let request else { return }
                editor.presentedAttachment = nil
                openWindow(value: AttachmentWindowID(documentID: model.documentID, attachmentID: request.attachmentID))
            }
            #endif
            .fileImporter(isPresented: $editor.isFileImporterPresented, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in editor.attachPickedFiles(result) }
            .alert("Attach File", isPresented: Binding(get: { editor.fileImportError != nil },
                                                      set: { if !$0 { editor.fileImportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editor.fileImportError ?? "")
            }
            .onAppear {
                editor.undoManager = undoManager
                editor.mapOpener = mapOpener ?? defaultMapOpener
                editor.refreshUndoState()
                OpenDocumentRegistry.shared.register(model, undoManager: undoManager)
                #if DEBUG
                DebugLaunchActions.run(editor)
                #if os(macOS)
                DebugFocusProbe.run(editor)
                #endif
                #endif
            }
            .onDisappear { OpenDocumentRegistry.shared.unregister(model) }
            .onChange(of: undoManager) { _, manager in
                editor.undoManager = manager
                editor.refreshUndoState()
                OpenDocumentRegistry.shared.register(model, undoManager: manager)
            }
            .onChange(of: model.map) { _, _ in editor.validateSelection() }
            .onReceive(UndoManager.changes(of: undoManager)) { _ in editor.refreshUndoState() }
    }
}

extension ContentView {
    /// macOS: a new tab of this editor's window (or the open map's tab).
    private var defaultMapOpener: MapOpener? {
        #if os(macOS)
        let editor = editor
        return { [weak editor] url, topicID, completion in
            MapTabOpener.open(url, revealing: topicID, from: editor?.hostWindow) { outcome in
                if case let .failed(message) = outcome { completion(message) } else { completion(nil) }
            }
        }
        #else
        return nil
        #endif
    }
}

#Preview {
    ContentView(model: MindMapModel())
}
