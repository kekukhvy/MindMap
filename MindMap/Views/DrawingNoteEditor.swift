import Combine
import PencilKit
import SwiftUI

/// Handwritten note (PencilKit drawing): title field + canvas.
/// - iPad: `PencilCanvas` (PKCanvasView + PKToolPicker), Pencil-only by
///   default with a persisted "Draw with Finger" toggle.
/// - macOS: `MacDrawingBoard` renders the drawing (zoom/scroll) and offers
///   basic mouse drawing (pen / stroke eraser); full editing is on iPad.
/// Every change is written through `MindMapModel.setAttachmentContent`
/// ("Draw" steps on the DOCUMENT's undo manager → dirty + autosave);
/// undo/redo reload the canvas from the store.
struct DrawingNoteEditor: View {
    let model: MindMapModel
    let attachment: Attachment
    let undoManager: UndoManager?

    @State private var title = ""
    @State private var didLoad = false
    @State private var canUndo = false
    @State private var canRedo = false
    @FocusState private var titleFocused: Bool
    #if os(iOS)
    @AppStorage(PencilCanvas.fingerDrawingKey) private var fingerDrawing = false
    @State private var flusher = DrawingFlusher()
    #else
    @AppStorage("MindMap.macDrawingTool") private var tool: MacDrawingTool = .pen
    @AppStorage("MindMap.macDrawingColor") private var inkHex = MacDrawingBoard.inkColors[0].hex
    #endif

    private var store: AttachmentStore { model.attachmentStore }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            canvas
        }
        .toolbar { toolbar }
        .onAppear(perform: load)
        .onChange(of: attachment.title) { _, newTitle in
            if !titleFocused { title = newTitle }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .onDisappear(perform: commitTitle)
        .onReceive(UndoManager.changes(of: undoManager)) { _ in refreshUndoState() }
    }

    @ViewBuilder private var canvas: some View {
        #if os(iOS)
        PencilCanvas(model: model, attachmentID: attachment.id, fileName: attachment.fileName,
                     revision: store.revision(of: attachment.fileName), undoManager: undoManager,
                     fingerDrawing: fingerDrawing, flusher: flusher)
            .ignoresSafeArea(.container, edges: .bottom)
        #else
        VStack(spacing: 0) {
            MacDrawingBoard(data: store.data(for: attachment.fileName),
                            revision: store.revision(of: attachment.fileName),
                            tool: tool, inkColor: MacDrawingBoard.color(hex: inkHex), undoManager: undoManager) { data in
                model.setAttachmentContent(data, for: attachment.id, actionName: "Draw", coalescing: false,
                                           undoManager: undoManager)
            }
            Divider()
            Label("Edit on iPad for Apple Pencil handwriting. Here: view, zoom (pinch / ⌘-scroll) and basic mouse drawing.",
                  systemImage: "applepencil")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        #endif
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                .disabled(!canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { redo() }
                .disabled(!canRedo)
            #if os(iOS)
            Toggle(isOn: $fingerDrawing) { Label("Draw with Finger", systemImage: "hand.draw") }
                .help("Draw with your finger (otherwise only Apple Pencil draws and fingers scroll)")
            #else
            Picker("Tool", selection: $tool) {
                Label("View", systemImage: "hand.raised").tag(MacDrawingTool.view)
                Label("Pen", systemImage: "pencil.tip").tag(MacDrawingTool.pen)
                Label("Eraser", systemImage: "eraser").tag(MacDrawingTool.eraser)
            }
            .pickerStyle(.segmented)
            .help("Mouse tool: view only, draw, or erase whole strokes")
            Picker("Ink", selection: $inkHex) {
                ForEach(MacDrawingBoard.inkColors, id: \.hex) { ink in
                    Label(ink.name, systemImage: "circle.fill").tag(ink.hex)
                }
            }
            .help("Pen color")
            .disabled(tool != .pen)
            #endif
        }
    }

    private func load() {
        guard !didLoad else { return }
        title = attachment.title
        didLoad = true
        refreshUndoState()
    }

    private func undo() {
        #if os(iOS)
        flusher.flush()
        #endif
        if undoManager?.canUndo == true { undoManager?.undo() }
    }

    private func redo() {
        #if os(iOS)
        flusher.flush()
        #endif
        if undoManager?.canRedo == true { undoManager?.redo() }
    }

    private func commitTitle() {
        guard didLoad else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            title = attachment.title
            return
        }
        model.renameAttachment(attachment.id, to: trimmed, undoManager: undoManager)
    }

    private func refreshUndoState() {
        let undo = undoManager?.canUndo ?? false, redo = undoManager?.canRedo ?? false
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
    }
}
