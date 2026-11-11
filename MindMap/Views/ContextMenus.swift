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
        Button("Add Child Topic", systemImage: "arrow.turn.down.right") {
            editor.select(id)
            editor.addChild()
        }
        Button("Add Sibling Topic", systemImage: "plus") {
            editor.select(id)
            editor.addSibling()
        }
        .disabled(info?.isTreeRoot ?? true)
        Button("Edit Text", systemImage: "pencil") { editor.beginEditing(id) }
        if info?.hasChildren == true {
            Button(info?.isCollapsed == true ? "Expand" : "Collapse",
                   systemImage: info?.isCollapsed == true ? "plus.circle" : "minus.circle") {
                editor.toggleCollapse(id)
            }
        }
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
    }
}
