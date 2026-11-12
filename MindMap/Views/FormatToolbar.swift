import SwiftUI

/// XMind-like toolbar groups. iPad (editor role): undo/redo capsule on the
/// leading side next to the title, tools capsule in the center (relationship,
/// add subtopic, boundary, note, insert "+"), Format (paintbrush) and More ("…")
/// trailing. macOS: the same groups in a native toolbar (undo/redo at the
/// navigation edge, tools centered, Format/More trailing).
struct FormatToolbar: ToolbarContent {
    let editor: EditorController

    #if os(iOS)
    private static let historyPlacement = ToolbarItemPlacement.topBarLeading
    private static let toolsPlacement = ToolbarItemPlacement.secondaryAction
    #else
    private static let historyPlacement = ToolbarItemPlacement.navigation
    private static let toolsPlacement = ToolbarItemPlacement.principal
    #endif

    private var selectedTopic: UUID? {
        editor.selectedID.flatMap { editor.scene.nodes[$0] != nil ? $0 : nil }
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: Self.historyPlacement) {
            Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                .disabled(!editor.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { editor.redo() }
                .disabled(!editor.canRedo)
        }
        ToolbarItemGroup(placement: Self.toolsPlacement) {
            Button("Relationship", systemImage: "arrow.triangle.turn.up.right.diamond") {
                if let id = selectedTopic { editor.beginRelationship(from: id) }
            }
            .disabled(selectedTopic == nil)
            Button("Add Subtopic", systemImage: "arrow.turn.down.right") { editor.addChild() }
            Button("Add Sibling Topic", systemImage: "plus.rectangle") { editor.addSibling() }
            Button("Boundary", systemImage: "square.dashed") {
                if selectedTopic != nil { editor.addBoundaryFromSelection() }
            }
            .disabled(selectedTopic == nil || editor.model.map.movableTopics(editor.selectedIDs).isEmpty)
            Button("Note", systemImage: "note.text") {
                if let id = selectedTopic { editor.openOrAddNote(id) }
            }
            .help("Add or open the note of the selected topic (⇧⌘N)")
            .disabled(selectedTopic == nil)
            Menu("Insert", systemImage: "plus") { InsertMenuItems(editor: editor) }
            #if os(iOS)
            // Select mode: taps toggle topics, drags draw a selection band.
            Button(editor.isSelectMode ? "Done Selecting" : "Select",
                   systemImage: editor.isSelectMode ? "checkmark.circle.fill" : "checkmark.circle") {
                editor.isSelectMode.toggle()
            }
            #endif
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Format", systemImage: "paintbrush") {
                if let item = editor.selectedItem {
                    CanvasItemMenu(editor: editor, item: item)
                } else if let id = selectedTopic {
                    NodeFormatMenus(editor: editor, id: id)
                } else {
                    Text("Select a topic, relationship or boundary")
                }
            }
            Menu("More", systemImage: "ellipsis.circle") {
                Menu("Theme", systemImage: "paintpalette") { ThemeMenuItems(editor: editor) }
                Menu("Outline", systemImage: "list.bullet.indent") { OutlineMenuItems(editor: editor) }
                Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                    editor.zoomToFit()
                }
            }
        }
    }
}

#if os(iOS)
/// XMind iPad bottom-left round button: outline / overview actions.
struct OutlineCornerButton: View {
    let editor: EditorController

    var body: some View {
        Menu {
            OutlineMenuItems(editor: editor)
            Divider()
            Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                editor.zoomToFit()
            }
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(white: 0.2))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
        .accessibilityLabel("Outline")
        .padding(16)
    }
}
#endif
