import SwiftUI

struct MindMapEditorKey: FocusedValueKey {
    typealias Value = EditorController
}

struct MindMapCommandStateKey: FocusedValueKey {
    typealias Value = EditorCommandState
}

extension FocusedValues {
    var mindMapEditor: EditorController? {
        get { self[MindMapEditorKey.self] }
        set { self[MindMapEditorKey.self] = newValue }
    }

    var mindMapCommandState: EditorCommandState? {
        get { self[MindMapCommandStateKey.self] }
        set { self[MindMapCommandStateKey.self] = newValue }
    }
}

/// Menu bar commands (macOS, and the iPad menu bar). Plain-key shortcuts
/// (Tab, Return, Delete, Space) are attached on macOS only, and items are
/// disabled while a topic is being edited so keys reach the text field.
/// Undo/Redo come from the system Edit menu (document UndoManager).
struct MindMapCommands: Commands {
    @FocusedValue(\.mindMapEditor) private var editor
    @FocusedValue(\.mindMapCommandState) private var state

    /// Topic commands need the canvas focused and no inline editing.
    private var canAct: Bool { editor != nil && state?.isEditing == false }
    private var hasSelection: Bool { canAct && state?.hasSelection == true }
    private var hasNodeSelection: Bool { canAct && state?.hasNodeSelection == true }

    var body: some Commands {
        CommandMenu("Topic") {
            Button("Add Child Topic") { editor?.perform(.addChild) }
                .plainKeyShortcut(.tab)
                .disabled(!canAct)
            Button("Add Sibling Topic") { editor?.perform(.addSibling) }
                .plainKeyShortcut(.return)
                .disabled(!canAct)
            Button("Rename") { editor?.perform(.edit) }
                .plainKeyShortcut(.space)
                .disabled(!hasSelection)
            Button(state?.selectionIsCollapsed == true ? "Expand" : "Collapse") {
                editor?.perform(.toggleCollapse)
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(!hasNodeSelection || state?.selectionHasChildren != true)
            Button("Expand Branch") { editor?.expandBranch() }
                .disabled(!hasNodeSelection || state?.selectionHasChildren != true)
            Button("Collapse Branch") { editor?.collapseBranch() }
                .disabled(!hasNodeSelection || state?.selectionHasChildren != true)
            Button("Reset Position") { editor?.resetPositions(in: editor?.selectedID) }
                .disabled(!hasNodeSelection || state?.selectionIsFreelyPositioned != true)
            Divider()
            Button("Floating Topic") { editor?.addFloatingTopic() }
                .disabled(!canAct)
            Button("Relationship") { editor?.perform(.addRelationship) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!hasNodeSelection)
            Button("Boundary") { editor?.perform(.addBoundary) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!hasNodeSelection || state?.selectionIsMainRoot == true)
            Button(state?.selectionHasNote == true ? "Open Note" : "Add Note") { editor?.perform(.note) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!hasNodeSelection)
            Button(state?.selectionHasDrawing == true ? "Open Handwritten Note" : "Add Handwritten Note") {
                editor?.perform(.handwrittenNote)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!hasNodeSelection)
            Divider()
            Button("Delete") { editor?.perform(.delete) }
                .plainKeyShortcut(.delete)
                .disabled(!hasSelection || state?.selectionIsMainRoot == true)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { editor?.zoom(by: 1.25) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom Out") { editor?.zoom(by: 0.8) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom to Fit") { editor?.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(editor == nil)
            Divider()
            ForEach(1...4, id: \.self) { level in
                Button("Collapse to Level \(level)") { editor?.collapseToLevel(level) }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .option])
                    .disabled(!canAct)
            }
            Button("Expand All") { editor?.expandAll() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!canAct)
            Button("Reset All Positions") { editor?.resetPositions() }
                .disabled(!canAct)
        }
    }
}

extension View {
    /// Keyboard shortcut without modifiers on macOS; no-op on iPad, where
    /// the canvas key handler (onKeyPress) provides these keys.
    @ViewBuilder
    func plainKeyShortcut(_ key: KeyEquivalent) -> some View {
        #if os(macOS)
        keyboardShortcut(key, modifiers: [])
        #else
        self
        #endif
    }
}
