import SwiftUI

/// Viewer/editor of one attachment, chosen by kind. Shown in a sheet on
/// iPad (`AttachmentSheet`) and in its own window on macOS
/// (`AttachmentWindow`); both edit the document's model and store.
struct AttachmentEditorView: View {
    let model: MindMapModel
    let attachmentID: UUID
    let undoManager: UndoManager?

    var body: some View {
        if let attachment = model.attachment(attachmentID) {
            Group {
                switch attachment.kind {
                case .markdown:
                    MarkdownNoteEditor(model: model, attachment: attachment, undoManager: undoManager)
                case .drawing:
                    DrawingNoteEditor(model: model, attachment: attachment, undoManager: undoManager)
                case .file:
                    FileAttachmentView(model: model, attachment: attachment, undoManager: undoManager)
                }
            }
            .navigationTitle(attachment.title.isEmpty ? attachment.kind.displayName : attachment.title)
        } else {
            // Removed (e.g. "Add Note" undone): redo brings it back here.
            ContentUnavailableView("Attachment Removed", systemImage: "trash",
                                   description: Text("This attachment is no longer in the map."))
                .toolbar {
                    ToolbarItem {
                        Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                            .disabled(undoManager?.canRedo != true)
                    }
                }
        }
    }
}

/// Toolbar trash of an attachment editor: "Delete Note" / "Delete
/// Handwritten Note" / "Delete File" (one undo step), then closes it.
struct DeleteAttachmentButton: View {
    let model: MindMapModel
    let attachmentID: UUID
    let undoManager: UndoManager?
    let close: () -> Void

    var body: some View {
        let label = MindMapModel.deleteActionName(for: model.attachment(attachmentID)?.kind)
        Button(label, systemImage: "trash", role: .destructive) {
            model.deleteAttachment(attachmentID, undoManager: undoManager)
            close()
        }
        .help(label)
        .disabled(model.attachment(attachmentID) == nil)
    }
}

#if os(iOS)
/// iPad: resizable sheet (medium / large detents, drag indicator) with
/// Delete + Done; handwriting is a full-screen cover with the same buttons.
/// When it goes away, a note / drawing left empty is removed
/// (`MindMapModel.discardIfEmpty`).
struct AttachmentSheet: View {
    let model: MindMapModel
    let attachmentID: UUID
    let undoManager: UndoManager?
    /// Handwriting: full-screen cover (no detents, no swipe-down while writing).
    var fullScreen = false
    @State private var detent: PresentationDetent = .large
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AttachmentEditorView(model: model, attachmentID: attachmentID, undoManager: undoManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        DeleteAttachmentButton(model: model, attachmentID: attachmentID, undoManager: undoManager) {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents(fullScreen ? [.large] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(fullScreen ? .hidden : .visible)
        .presentationContentInteraction(.scrolls)
        .modifier(PageSizedSheet())
        .onDisappear {
            // After the editor flushed pending strokes / text.
            let model = model, id = attachmentID, undoManager = undoManager
            DispatchQueue.main.async { model.discardIfEmpty(id, undoManager: undoManager) }
        }
    }
}

/// iPadOS 18+: page-sized sheet (taller/wider than the default form sheet).
private struct PageSizedSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}
#endif

#if os(macOS)
/// macOS: content of one attachment window (`AttachmentWindows`). The
/// document is looked up in `OpenDocumentRegistry`; the editor fills the
/// whole window. Toolbar: Delete (trash) and Done (Esc); the window closes
/// itself once its map closes.
struct AttachmentWindowContent: View {
    let windowID: AttachmentWindowID
    let close: () -> Void
    /// Window title = attachment title (kept in sync on rename).
    let setTitle: (String) -> Void
    @State private var registry = OpenDocumentRegistry.shared
    @State private var wasConnected = false

    private var entry: OpenDocumentRegistry.Entry? {
        registry.entry(for: windowID.documentID)
    }

    private var title: String {
        guard let attachment = entry?.model?.attachment(windowID.attachmentID) else { return "Note" }
        return attachment.title.isEmpty ? attachment.kind.displayName : attachment.title
    }

    var body: some View {
        Group {
            if let entry, let model = entry.model {
                AttachmentEditorView(model: model, attachmentID: windowID.attachmentID,
                                     undoManager: entry.undoManager)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            DeleteAttachmentButton(model: model, attachmentID: windowID.attachmentID,
                                                   undoManager: entry.undoManager, close: close)
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label("Map Not Open", systemImage: "doc.questionmark")
                } description: {
                    Text("Open its map and the note again to edit it.")
                } actions: {
                    Button("Close", action: close)
                }
                .navigationTitle("Note")
            }
        }
        .frame(minWidth: AttachmentWindowChrome.minSize.width, maxWidth: .infinity,
               minHeight: AttachmentWindowChrome.minSize.height, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            // Visible close button; Esc closes too.
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
                    .help("Close this window (Esc)")
            }
        }
        .onChange(of: title, initial: true) { _, title in setTitle(title) }
        .onAppear { wasConnected = entry != nil }
        .onChange(of: entry != nil) { _, connected in
            if connected {
                wasConnected = true
            } else if wasConnected {
                AttachmentWindows.shared.closeWindows(of: windowID.documentID)
            }
        }
    }
}
#endif
