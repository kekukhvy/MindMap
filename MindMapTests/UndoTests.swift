import Foundation
import Testing
@testable import MindMap

struct UndoTests {
    static func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    @Test func addDeleteUndoRedo() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let original = model.map
        let a = try #require(model.addChild(to: model.root.id, text: "a", undoManager: undo))
        let b = try #require(model.addSibling(after: a, text: "b", undoManager: undo))
        #expect(model.addSibling(after: model.root.id, undoManager: undo) == nil)
        #expect(model.delete(model.root.id, undoManager: undo) == false)
        #expect(model.delete(a, undoManager: undo))
        #expect(model.root.children.map(\.id) == [b])

        undo.undo()
        #expect(model.root.children.map(\.id) == [a, b])
        #expect(undo.undoActionName == "Add Topic")
        undo.undo()
        undo.undo()
        #expect(model.map == original)
        #expect(undo.canUndo == false)

        undo.redo()
        undo.redo()
        undo.redo()
        #expect(model.root.children.map(\.id) == [b])
    }

    @Test func reparentCollapseRenameUndo() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let a = try #require(model.addChild(to: model.root.id, text: "a", undoManager: undo))
        let b = try #require(model.addChild(to: model.root.id, text: "b", undoManager: undo))
        try #require(model.toggleCollapse(a, undoManager: undo))
        let before = model.map
        #expect(model.reparent(a, to: a, undoManager: undo) == false)
        #expect(model.reparent(b, to: a, undoManager: undo))
        #expect(model.root.node(withID: a)?.isCollapsed == false) // target expanded
        #expect(model.rename(b, to: "B", undoManager: undo))
        undo.undo()
        #expect(model.root.node(withID: b)?.text == "b")
        undo.undo()
        #expect(model.map == before)
        undo.redo()
        #expect(model.root.parent(of: b)?.id == a)
    }

    @Test func layoutStyleUndo() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let a = try #require(model.addChild(to: model.root.id, undoManager: undo))
        #expect(model.setLayoutStyle(.treeDown, for: a, undoManager: undo))
        #expect(model.root.node(withID: a)?.layoutStyle == .treeDown)
        #expect(undo.undoActionName == "Change Layout")
        undo.undo()
        #expect(model.root.node(withID: a)?.layoutStyle == nil)
        undo.redo()
        #expect(model.root.node(withID: a)?.layoutStyle == .treeDown)
    }

    @Test func branchShapeIsOneUndoStep() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let a = try #require(model.addChild(to: model.root.id, undoManager: undo))
        let a1 = try #require(model.addChild(to: a, undoManager: undo))
        let a2 = try #require(model.addChild(to: a1, undoManager: undo))
        let ids = [a, a1, a2]
        #expect(model.setShape(.capsule, for: a, wholeBranch: true, undoManager: undo))
        #expect(ids.allSatisfy { model.root.node(withID: $0)?.shape == .capsule })
        #expect(model.setBorderStyle(.dashed, for: a1, undoManager: undo))
        #expect(model.root.node(withID: a)?.borderStyle == nil)
        #expect(model.root.node(withID: a1)?.borderStyle == .dashed)
        undo.undo()
        #expect(model.root.node(withID: a1)?.borderStyle == nil)
        undo.undo() // single step reverts the whole branch
        #expect(ids.allSatisfy { model.root.node(withID: $0)?.shape == nil })
        #expect(model.root.subtreeCount == 4)
        undo.redo()
        #expect(ids.allSatisfy { model.root.node(withID: $0)?.shape == .capsule })
    }
}
