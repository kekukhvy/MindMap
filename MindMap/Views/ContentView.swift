import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Editor window/scene for one document: canvas + toolbar + menu wiring.
struct ContentView: View {
    let model: MindMapModel
    @State private var editor: EditorController
    @Environment(\.undoManager) private var undoManager
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    init(model: MindMapModel) {
        self.model = model
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
            #if os(iOS)
            .sheet(item: presentedAttachment(fullScreen: false)) { request in
                AttachmentSheet(model: model, attachmentID: request.attachmentID, undoManager: undoManager)
            }
            .fullScreenCover(item: presentedAttachment(fullScreen: true)) { request in
                AttachmentSheet(model: model, attachmentID: request.attachmentID, undoManager: undoManager)
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
                editor.refreshUndoState()
                OpenDocumentRegistry.shared.register(model, undoManager: undoManager)
                #if DEBUG
                DebugLaunchActions.run(editor)
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

#Preview {
    ContentView(model: MindMapModel())
}
