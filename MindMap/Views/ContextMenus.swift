import SwiftUI

/// Long-press (iPad) / right-click (macOS) menu of a topic.
struct NodeContextMenu: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        Group { items }
            // Right click / long press selects the topic first.
            .onAppear { if editor.selectedID != id { editor.select(id) } }
    }

    @ViewBuilder private var items: some View {
        let info = editor.scene.nodes[id]
        let isMainRoot = id == editor.model.root.id
        let isFloatingRoot = editor.model.map.isFloatingRoot(id)
        Button("Rename", systemImage: "pencil") { editor.beginEditing(id) }
        Button("Add Child Topic", systemImage: "arrow.turn.down.right") {
            editor.select(id)
            editor.addChild()
        }
        Button("Add Sibling Topic", systemImage: "plus") {
            editor.select(id)
            editor.addSibling()
        }
        .disabled(info?.isTreeRoot ?? true)
        if info?.hasChildren == true {
            Button(info?.isCollapsed == true ? "Expand" : "Collapse",
                   systemImage: info?.isCollapsed == true ? "plus.circle" : "minus.circle") {
                editor.toggleCollapse(id)
            }
            Button("Expand Branch", systemImage: "plus.square.on.square") { editor.expandBranch(id) }
            Button("Collapse Branch", systemImage: "minus.square") { editor.collapseBranch(id) }
        }
        if editor.isFreelyPositioned(id) {
            Button("Reset Position", systemImage: "arrow.uturn.backward.circle") { editor.resetPositions(in: id) }
        }
        if isMainRoot {
            Divider()
            OutlineMenuItems(editor: editor)
        }
        Divider()
        AttachmentMenuItems(editor: editor, id: id)
        Divider()
        Button("Relationship", systemImage: "arrow.triangle.turn.up.right.diamond") {
            editor.beginRelationship(from: id)
        }
        if !isMainRoot {
            Button("Boundary", systemImage: "square.dashed") { editor.addBoundary(around: id) }
        }
        if isFloatingRoot {
            Button("Attach to…", systemImage: "link") { editor.beginAttach(id) }
        } else if !isMainRoot {
            Button("Detach as Floating", systemImage: "rectangle.dashed") { editor.detachAsFloating(id) }
        }
        Divider()
        NodeFormatMenus(editor: editor, id: id)
        if !isMainRoot {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                editor.select(id)
                editor.deleteSelection()
            }
        }
    }
}

/// Secondary-click menu on empty canvas (macOS).
struct CanvasBackgroundMenu: View {
    let editor: EditorController

    var body: some View {
        Button("Add Floating Topic Here", systemImage: "rectangle.dashed") {
            editor.addFloatingTopic(at: editor.contextPoint)
        }
        Divider()
        OutlineMenuItems(editor: editor)
    }
}

/// Map-wide outline items: Collapse to Level 1-4, Expand All, Reset All
/// Positions (context menus and the toolbar Outline menu; the menu bar
/// View menu has the same items with Cmd+Option+1...4 / 0).
struct OutlineMenuItems: View {
    let editor: EditorController

    var body: some View {
        ForEach(1...4, id: \.self) { level in
            Button("Collapse to Level \(level)") { editor.collapseToLevel(level) }
        }
        Button("Expand All", systemImage: "arrow.down.right.and.arrow.up.left") { editor.expandAll() }
        Button("Reset All Positions", systemImage: "arrow.uturn.backward.circle") { editor.resetPositions() }
            .disabled(!editor.hasManualPosition())
    }
}

/// Notes / attachments of a topic: Add Note / Handwritten Note / Attach
/// File… / Paste File, then each attachment with
/// Open, Move and Remove (icons on the topic open them directly).
struct AttachmentMenuItems: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        let attachments = editor.attachments(of: id)
        Button("Add Note", systemImage: "note.text.badge.plus") { editor.addNote(to: id) }
        Button("Add Handwritten Note", systemImage: "pencil.and.scribble") { editor.addDrawing(to: id) }
        Button("Attach File…", systemImage: "paperclip") { editor.beginAttachFile(to: id) }
        Button("Paste File", systemImage: "doc.on.clipboard") {
            editor.select(id)
            editor.pasteFiles(to: id)
        }
        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
            Menu(attachment.title.isEmpty ? attachment.kind.displayName : attachment.title,
                 systemImage: attachment.kind.systemImage) {
                Button("Open", systemImage: "arrow.up.forward.square") {
                    editor.select(id)
                    editor.openAttachment(attachment.id)
                }
                if attachments.count > 1 {
                    Button("Move Left", systemImage: "arrow.left") { editor.moveAttachment(attachment.id, by: -1) }
                        .disabled(index == 0)
                    Button("Move Right", systemImage: "arrow.right") { editor.moveAttachment(attachment.id, by: 1) }
                        .disabled(index == attachments.count - 1)
                }
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive) { editor.removeAttachment(attachment.id) }
            }
        }
    }
}
