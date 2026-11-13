import Foundation
import Testing
@testable import MindMap

/// A just-added topic emptied and committed is deleted; the arrow key
/// towards a collapsed topic's children expands it.
@MainActor
struct EditingKeysTests {
    @Test func emptiedNewTopicIsDeletedOnReturn() throws {
        let topic = Node(text: "Topic")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap,
                                                                                   children: [topic]))))
        editor.undoManager = UndoTests.makeUndoManager()
        editor.select(topic.id)
        editor.addChild()
        let new = try #require(editor.editingID)
        editor.updateDraft("", editing: new)
        #expect(!editor.handleEditorReturn(shift: false, option: false, editing: new))
        #expect(editor.model.map.node(withID: new) == nil)
        #expect(editor.model.map.node(withID: topic.id)?.children.isEmpty == true)
        #expect(editor.selectedID == topic.id)
    }

    @Test func emptiedExistingTopicIsKept() {
        let topic = Node(text: "Topic")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap,
                                                                                   children: [topic]))))
        editor.undoManager = UndoTests.makeUndoManager()
        editor.select(topic.id)
        editor.beginEditing()
        editor.updateDraft("", editing: topic.id)
        editor.commitEditing()
        #expect(editor.model.map.node(withID: topic.id)?.text == "")
    }

    @Test func arrowTowardsChildrenExpandsACollapsedTopic() {
        let child = Node(text: "child")
        let right = Node(text: "right", isCollapsed: true, children: [child])
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap,
                                                                                   children: [right]))))
        editor.undoManager = UndoTests.makeUndoManager()
        editor.select(right.id)
        editor.move(.right)
        #expect(editor.model.map.node(withID: right.id)?.isCollapsed == false)
        #expect(editor.selectedID == right.id)
        // Expanded: the same key moves to the child.
        editor.move(.right)
        #expect(editor.selectedID == child.id)
        // The key back to the parent does not expand.
        editor.select(right.id)
        _ = editor.model.toggleCollapse(right.id, undoManager: editor.undoManager)
        editor.move(.left)
        #expect(editor.model.map.node(withID: right.id)?.isCollapsed == true)
        #expect(editor.selectedID == editor.model.root.id)
    }
}
