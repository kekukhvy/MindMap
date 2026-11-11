import SwiftUI

/// Toolbar: undo/redo (for iPad without keyboard), add topics, Insert
/// (floating topic, relationship, boundary), Format menu for the selection, map theme, zoom to fit.
struct FormatToolbar: ToolbarContent {
    let editor: EditorController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                .disabled(!editor.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { editor.redo() }
                .disabled(!editor.canRedo)
            Button("Add Child Topic", systemImage: "arrow.turn.down.right") { editor.addChild() }
            Button("Add Sibling Topic", systemImage: "plus.rectangle") { editor.addSibling() }
            Menu("Insert", systemImage: "plus.square.on.square") { InsertMenuItems(editor: editor) }
            Menu("Format", systemImage: "paintbrush") {
                if let item = editor.selectedItem {
                    CanvasItemMenu(editor: editor, item: item)
                } else if let id = editor.selectedID, editor.scene.nodes[id] != nil {
                    NodeFormatMenus(editor: editor, id: id)
                } else {
                    Text("Select a topic, relationship or boundary")
                }
            }
            Menu("Theme", systemImage: "paintpalette") { ThemeMenuItems(editor: editor) }
            Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                editor.zoomToFit()
            }
        }
    }
}
