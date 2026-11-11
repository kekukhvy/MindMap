import Foundation
import Testing
@testable import MindMap

struct EditorControllerTests {
    @Test func keyboardFlowIsUndoable() throws {
        let undo = UndoTests.makeUndoManager()
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap))))
        editor.undoManager = undo
        let root = editor.model.root.id
        editor.select(root)
        #expect(editor.perform(.addChild))
        let child = try #require(editor.selectedID)
        #expect(editor.editingID == child)
        #expect(editor.draftText == "Main Topic")
        // Keys are ignored while editing.
        #expect(!editor.perform(.addSibling))
        editor.draftText = "Ideas"
        editor.commitEditing()
        #expect(editor.model.map.node(withID: child)?.text == "Ideas")
        #expect(editor.editingID == nil)

        editor.perform(.addSibling)
        let sibling = try #require(editor.selectedID)
        editor.commitEditing()
        #expect(editor.model.root.children.map(\.id) == [child, sibling])
        editor.perform(.move(.up))
        #expect(editor.selectedID == child)
        editor.perform(.editReplacing("X"))
        #expect(editor.draftText == "X")
        editor.commitEditing()
        #expect(editor.model.map.node(withID: child)?.text == "X")

        editor.perform(.delete)
        #expect(editor.selectedID == sibling)
        undo.undo()
        #expect(editor.model.root.children.count == 2)
        undo.undo() // rename X
        undo.undo() // add sibling
        editor.validateSelection()
        #expect(editor.model.map.node(withID: child)?.text == "Ideas")
        #expect(editor.selectedID == nil || editor.scene.nodes[editor.selectedID!] != nil)
    }

    @Test func dragReparentsOntoTarget() throws {
        let undo = UndoTests.makeUndoManager()
        let a = Node(text: "a"), b = Node(text: "b")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", children: [a, b]))))
        editor.undoManager = undo
        let target = try #require(editor.scene.layout.frames[b.id])
        let location = editor.viewport.toScreen(CGPoint(x: target.midX, y: target.midY))
        editor.updateDrag(a.id, translation: .zero, location: location)
        #expect(editor.drag?.targetID == b.id)
        editor.endDrag()
        #expect(editor.model.map.parentID(of: a.id) == b.id)
        undo.undo()
        #expect(editor.model.map.parentID(of: a.id) == editor.model.root.id)
    }
}
