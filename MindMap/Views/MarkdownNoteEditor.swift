import Combine
import SwiftUI

/// Title field + plain Markdown editor with a Preview toggle. A new note
/// starts empty (placeholder text shown) and is a draft until its first
/// text (`MindMapModel+Drafts`); closed empty, it disappears. Every text
/// change is written to the document's `AttachmentStore` as an undoable
/// "Edit Note" step on the document's undo manager (dirty + autosave);
/// external changes (undo/redo, revert) reload the text.
struct MarkdownNoteEditor: View {
    let model: MindMapModel
    let attachment: Attachment
    let undoManager: UndoManager?

    @State private var text: String
    @State private var title: String
    @State private var didLoad = true
    @State private var isPreview = false
    @State private var canUndo = false
    @State private var canRedo = false
    @AppStorage("MindMap.noteMonospaced") private var monospaced = false
    @FocusState private var titleFocused: Bool

    /// Text and title come from the document right away (not in onAppear),
    /// so the first keystroke never races an unloaded editor.
    init(model: MindMapModel, attachment: Attachment, undoManager: UndoManager?) {
        self.model = model
        self.attachment = attachment
        self.undoManager = undoManager
        _text = State(initialValue: MarkdownNote.text(model.content(of: attachment.id)))
        _title = State(initialValue: attachment.title)
    }

    private var store: AttachmentStore { model.attachmentStore }
    private var storedText: String { MarkdownNote.text(model.content(of: attachment.id)) }

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
                MarkdownTextView(text: $text, monospaced: monospaced, undoManager: undoManager, onEdit: save)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(MarkdownTextView.placeholder)
                                .font(.system(size: MarkdownTextView.fontSize(monospaced: monospaced),
                                              design: monospaced ? .monospaced : .default))
                                .foregroundStyle(.tertiary)
                                .padding(MarkdownTextView.textOrigin)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .toolbar { toolbar }
        .onAppear(perform: load)
        .onChange(of: text) { _, newText in save(newText) }
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

    private func save(_ newText: String) {
        guard didLoad, newText != storedText else { return }
        model.setAttachmentContent(MarkdownNote.data(newText), for: attachment.id, undoManager: undoManager)
    }

    private func load() {
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
