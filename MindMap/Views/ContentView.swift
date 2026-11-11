import Combine
import SwiftUI

/// Editor window/scene for one document: canvas + toolbar + menu wiring.
struct ContentView: View {
    let model: MindMapModel
    @State private var editor: EditorController
    @Environment(\.undoManager) private var undoManager

    init(model: MindMapModel) {
        self.model = model
        _editor = State(initialValue: EditorController(model: model))
    }

    private var undoChanges: AnyPublisher<Notification, Never> {
        let center = NotificationCenter.default
        return Publishers.MergeMany(
            center.publisher(for: .NSUndoManagerDidCloseUndoGroup),
            center.publisher(for: .NSUndoManagerDidUndoChange),
            center.publisher(for: .NSUndoManagerDidRedoChange),
            center.publisher(for: .NSUndoManagerCheckpoint)
        )
        .filter { [weak undoManager] in $0.object as AnyObject? === undoManager }
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
    }

    var body: some View {
        CanvasView(editor: editor)
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar { FormatToolbar(editor: editor) }
            .focusedSceneValue(\.mindMapEditor, editor)
            .sheet(item: $editor.colorSheet) { request in
                ColorPickerSheet(request: request) { hex in editor.applyColorSheet(request, hex: hex) }
            }
            .onAppear {
                editor.undoManager = undoManager
                editor.refreshUndoState()
            }
            .onChange(of: undoManager) { _, manager in
                editor.undoManager = manager
                editor.refreshUndoState()
            }
            .onChange(of: model.map) { _, _ in editor.validateSelection() }
            .onReceive(undoChanges) { _ in editor.refreshUndoState() }
    }
}

#Preview {
    ContentView(model: MindMapModel())
}
