import SwiftUI

/// Viewer/editor of one attachment, chosen by kind. Shown in a sheet on
/// iPad (`AttachmentSheet`) and in its own window on macOS
/// (`AttachmentWindow`); both edit the document's model and store.
/// WP5 (drawing) and WP6 (file) plug their views into `body`.
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
                case .drawing, .file:
                    ContentUnavailableView(attachment.title.isEmpty ? attachment.kind.displayName : attachment.title,
                                           systemImage: attachment.kind.systemImage,
                                           description: Text("This kind of attachment cannot be opened yet."))
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

#if os(iOS)
/// iPad: large sheet with Done.
struct AttachmentSheet: View {
    let model: MindMapModel
    let attachmentID: UUID
    let undoManager: UndoManager?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AttachmentEditorView(model: model, attachmentID: attachmentID, undoManager: undoManager)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .modifier(PageSizedSheet())
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
/// macOS: one window per (document, attachment). The document is looked up
/// in `OpenDocumentRegistry`; a window restored after relaunch (or whose
/// map was closed) shows a placeholder, and closes once its map closes.
struct AttachmentWindow: View {
    let windowID: AttachmentWindowID?
    @State private var registry = OpenDocumentRegistry.shared
    @State private var wasConnected = false
    @Environment(\.dismiss) private var dismiss

    private var entry: OpenDocumentRegistry.Entry? {
        windowID.flatMap { registry.entry(for: $0.documentID) }
    }

    var body: some View {
        Group {
            if let windowID, let entry, let model = entry.model {
                AttachmentEditorView(model: model, attachmentID: windowID.attachmentID,
                                     undoManager: entry.undoManager)
            } else {
                ContentUnavailableView {
                    Label("Map Not Open", systemImage: "doc.questionmark")
                } description: {
                    Text("Open its map and the note again to edit it.")
                } actions: {
                    Button("Close") { dismiss() }
                }
                .navigationTitle("Note")
            }
        }
        .frame(minWidth: 380, idealWidth: 560, minHeight: 320, idealHeight: 640)
        .onAppear { wasConnected = entry != nil }
        .onChange(of: entry != nil) { _, connected in
            if connected {
                wasConnected = true
            } else if wasConnected {
                dismiss()
            }
        }
    }
}
#endif
