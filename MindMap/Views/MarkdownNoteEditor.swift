import Combine
import SwiftUI

/// Title field + plain Markdown editor with a Preview toggle. Every text
/// change is written to the document's `AttachmentStore` as an undoable
/// "Edit Note" step on the document's undo manager (dirty + autosave);
/// external changes (undo/redo, revert) reload the text.
struct MarkdownNoteEditor: View {
    let model: MindMapModel
    let attachment: Attachment
    let undoManager: UndoManager?

    @State private var text = ""
    @State private var title = ""
    @State private var didLoad = false
    @State private var isPreview = false
    @State private var canUndo = false
    @State private var canRedo = false
    @AppStorage("MindMap.noteMonospaced") private var monospaced = false
    @FocusState private var titleFocused: Bool

    private var store: AttachmentStore { model.attachmentStore }
    private var storedText: String { MarkdownNote.text(store.data(for: attachment.fileName)) }

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
            if isPreview {
                MarkdownPreview(text: text)
            } else {
                MarkdownTextView(text: $text, monospaced: monospaced, undoManager: undoManager)
            }
        }
        .toolbar { toolbar }
        .onAppear(perform: load)
        .onChange(of: text) { _, newText in
            guard didLoad, newText != storedText else { return }
            model.setAttachmentContent(MarkdownNote.data(newText), for: attachment.id, undoManager: undoManager)
        }
        .onChange(of: store.revision(of: attachment.fileName)) { _, _ in
            let current = storedText
            if current != text { text = current }
        }
        .onChange(of: attachment.title) { _, newTitle in
            if !titleFocused { title = newTitle }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .onDisappear(perform: commitTitle)
        .onReceive(UndoManager.changes(of: undoManager)) { _ in refreshUndoState() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                .disabled(!canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                .disabled(!canRedo)
            Picker("Mode", selection: $isPreview) {
                Text("Edit").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle(isOn: $monospaced) { Label("Monospaced", systemImage: "textformat.size") }
                .help("Monospaced font")
        }
    }

    private func load() {
        guard !didLoad else { return }
        text = storedText
        title = attachment.title
        didLoad = true
        refreshUndoState()
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
