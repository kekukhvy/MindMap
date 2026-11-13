import Foundation
import SwiftUI
import Testing
@testable import MindMap

/// Collapse to level / expand all / branch collapse (+ keys, selection).
struct OutlineTests {
    /// r -> a -> a1 -> a11 ; r -> b ; floating f -> f1 -> f11
    private func makeModel() -> (MindMapModel, ids: [String: UUID]) {
        let a11 = Node(text: "a11"), a1 = Node(text: "a1", children: [a11])
        let a = Node(text: "a", children: [a1]), b = Node(text: "b")
        let f11 = Node(text: "f11"), f1 = Node(text: "f1", children: [f11]), f = Node(text: "f", children: [f1])
        let map = MindMap(root: Node(text: "r", children: [a, b]),
                          floatingTopics: [FloatingTopic(node: f, position: CGPoint(x: 0, y: 300))])
        let ids = ["r": map.root.id, "a": a.id, "a1": a1.id, "a11": a11.id, "b": b.id,
                   "f": f.id, "f1": f1.id, "f11": f11.id]
        return (MindMapModel(map: map), ids)
    }

    private func collapsed(_ model: MindMapModel, _ ids: [String: UUID]) -> Set<String> {
        Set(ids.filter { model.map.node(withID: $0.value)?.isCollapsed == true }.keys)
    }

    @Test func collapseToLevelsAndExpandAllAreSingleSteps() {
        let undo = UndoTests.makeUndoManager()
        let (model, ids) = makeModel()
        // Level 1 = root + main topics visible (deeper parents collapsed too);
        // floating topics count from their own root.
        #expect(model.collapseToLevel(1, undoManager: undo))
        #expect(collapsed(model, ids) == ["a", "a1", "f1"])
        #expect(!model.collapseToLevel(1, undoManager: undo))
        #expect(model.collapseToLevel(2, undoManager: undo))
        #expect(collapsed(model, ids) == ["a1"])
        #expect(model.collapseToLevel(4, undoManager: undo))
        #expect(collapsed(model, ids).isEmpty)
        #expect(!model.expandAll(undoManager: undo))
        undo.undo()
        #expect(collapsed(model, ids) == ["a1"])
        undo.undo()
        #expect(collapsed(model, ids) == ["a", "a1", "f1"])
        #expect(model.expandAll(undoManager: undo))
        #expect(collapsed(model, ids).isEmpty)
        undo.undo()
        #expect(collapsed(model, ids) == ["a", "a1", "f1"])
    }

    @Test func sortChildrenIsOneUndoStepAndKeepsGrandchildren() {
        let undo = UndoTests.makeUndoManager()
        let grandchild = Node(text: "deep")
        let parent = Node(text: "List", children: [
            Node(text: "item 10"), Node(text: "Banana", children: [grandchild]), Node(text: "apple"), Node(text: "item 2"),
        ])
        let model = MindMapModel(map: MindMap(root: Node(text: "r", children: [parent])))
        let texts = { model.map.node(withID: parent.id)?.children.map(\.text) ?? [] }

        #expect(model.sortChildren(parent.id, ascending: true, undoManager: undo))
        #expect(texts() == ["apple", "Banana", "item 2", "item 10"])
        #expect(model.map.node(withID: parent.id)?.children[1].children.map(\.id) == [grandchild.id])
        // Already sorted: nothing to do, no undo step.
        #expect(!model.sortChildren(parent.id, ascending: true, undoManager: undo))
        #expect(model.sortChildren(parent.id, ascending: false, undoManager: undo))
        #expect(texts() == ["item 10", "item 2", "Banana", "apple"])
        #expect(undo.undoActionName == "Sort Children")
        undo.undo()
        #expect(texts() == ["apple", "Banana", "item 2", "item 10"])
        undo.undo()
        #expect(texts() == ["item 10", "Banana", "apple", "item 2"])
    }

    @Test func branchCollapseAndExpand() {
        let undo = UndoTests.makeUndoManager()
        let (model, ids) = makeModel()
        #expect(model.collapseBranch(ids["a"]!, undoManager: undo))
        #expect(collapsed(model, ids) == ["a", "a1"])
        #expect(!model.collapseBranch(ids["b"]!, undoManager: undo))
        #expect(model.expandAll(in: ids["a"]!, undoManager: undo))
        #expect(collapsed(model, ids).isEmpty)
        undo.undo()
        #expect(collapsed(model, ids) == ["a", "a1"])
        undo.undo()
        #expect(collapsed(model, ids).isEmpty)
    }

    @MainActor
    @Test func selectionMovesToVisibleAncestor() {
        let undo = UndoTests.makeUndoManager()
        let (model, ids) = makeModel()
        let editor = EditorController(model: model)
        editor.undoManager = undo
        editor.select(ids["a11"]!)
        editor.collapseToLevel(1)
        #expect(editor.selectedID == ids["a"])
        editor.expandAll()
        editor.select(ids["f11"]!)
        editor.collapseBranch(ids["f"]!)
        #expect(editor.selectedID == ids["f"])
    }

    @Test func outlineKeys() {
        #expect(KeyCommandMap.command(key: "1", modifiers: [.command, .option], characters: "¡") == .collapseToLevel(1))
        #expect(KeyCommandMap.command(key: "4", modifiers: [.command, .option], characters: "¢") == .collapseToLevel(4))
        #expect(KeyCommandMap.command(key: "0", modifiers: [.command, .option], characters: "º") == .expandAll)
        #expect(KeyCommandMap.command(key: "0", modifiers: .command, characters: "0") == .zoomToFit)
        #expect(KeyCommandMap.command(key: "5", modifiers: [.command, .option], characters: "∞") == nil)
        #expect(KeyCommandMap.command(key: KeyEquivalent(Character(KeyCommandMap.f2)), modifiers: [],
                                      characters: KeyCommandMap.f2) == .edit)
    }
}
