import CoreGraphics
import Foundation
import Testing
@testable import MindMap

/// Free positioning of tree topics (`Node.manualPosition`).
struct ManualPositionTests {
    let size = CGSize(width: 100, height: 40)

    private func layout(_ root: Node) -> TreeLayout.Result {
        TreeLayout().layout(root) { _ in size }
    }

    @Test func manualChildIsPlacedAtOffsetAndSiblingsReflow() throws {
        var root = TestTree.node("root", style: .rightMap, children: TestTree.leaves(3))
        let auto = layout(root)
        root.children[1].manualPosition = CGPoint(x: 400, y: 300)
        let result = layout(root)
        let moved = try #require(result.frames[root.children[1].id])
        #expect(approx(moved.midX, 400) && approx(moved.midY, 300))
        // Remaining two siblings are stacked as a pair, centered on the root.
        let first = try #require(result.frames[root.children[0].id])
        let last = try #require(result.frames[root.children[2].id])
        #expect(approx((first.midY + last.midY) / 2, 0))
        #expect(approx(last.minY - first.maxY, LayoutSpacing().rootVertical))
        #expect(first != auto.frames[root.children[0].id])
        // Connector still drawn from the parent, bounds include the moved topic.
        let connector = try #require(result.connectors.first { $0.childID == root.children[1].id })
        #expect(approx(connector.start.x, 50) && approx(connector.end.x, moved.minX))
        #expect(result.bounds.contains(moved))
    }

    @Test func balancedRootSideFollowsManualPosition() throws {
        let grandchild = Node(text: "g")
        var root = Node(text: "root", layoutStyle: .balancedMap,
                        children: [Node(text: "a", children: [grandchild]), Node(text: "b"), Node(text: "c")])
        root.children[0].manualPosition = CGPoint(x: -300, y: 120)
        let result = layout(root)
        let moved = try #require(result.frames[root.children[0].id])
        let kid = try #require(result.frames[grandchild.id])
        #expect(approx(moved.midX, -300) && approx(moved.midY, 120))
        // Left of the root: its subtree grows to the left.
        #expect(kid.maxX < moved.minX)
        let connector = try #require(result.connectors.first { $0.childID == root.children[0].id })
        #expect(approx(connector.start.x, -50) && approx(connector.end.x, moved.maxX))
    }

    @Test func manualDeepNodeDoesNotPushAncestorsSiblings() throws {
        var root = TestTree.node("root", style: .rightMap, children: [
            Node(text: "a", children: TestTree.leaves(2)), Node(text: "b")
        ])
        let before = layout(root).frames[root.children[1].id]
        root.children[0].children[1].manualPosition = CGPoint(x: 50, y: 900)
        let after = layout(root)
        // "a" now has one stacked child: its subtree is shorter, "b" moves up
        // instead of being pushed down by the far-away topic.
        let b = try #require(after.frames[root.children[1].id])
        #expect(b.minY < before!.minY)
        #expect(TestTree.overlappingPairs(after.frames) == 0)
    }

    @Test func verticalConnectorWhenDroppedBelowParent() throws {
        var root = TestTree.node("root", style: .rightMap, children: TestTree.leaves(1))
        root.children[0].manualPosition = CGPoint(x: 10, y: 200)
        let connector = try #require(layout(root).connectors.first)
        #expect(connector.startAxis == .vertical && approx(connector.start.y, 20))
    }

    @Test func setResetAndUndoAreSingleSteps() throws {
        let undo = UndoTests.makeUndoManager()
        let a = Node(text: "a", children: [Node(text: "a1")]), b = Node(text: "b")
        let model = MindMapModel(map: MindMap(root: Node(text: "r", children: [a, b])))
        #expect(model.setManualPosition(a.id, to: CGPoint(x: 1, y: 2), undoManager: undo))
        #expect(!model.setManualPosition(a.id, to: CGPoint(x: 1, y: 2), undoManager: undo))
        #expect(!model.setManualPosition(model.root.id, to: .zero, undoManager: undo))
        #expect(model.setManualPosition(a.children[0].id, to: CGPoint(x: 5, y: 5), undoManager: undo))
        #expect(model.map.hasManualPosition())
        #expect(model.resetPositions(undoManager: undo))
        #expect(!model.map.hasManualPosition())
        #expect(!model.resetPositions(undoManager: undo))
        undo.undo()
        #expect(model.map.node(withID: a.id)?.manualPosition == CGPoint(x: 1, y: 2))
        #expect(model.map.node(withID: a.children[0].id)?.manualPosition == CGPoint(x: 5, y: 5))
        #expect(model.resetPositions(in: a.children[0].id, undoManager: undo))
        #expect(model.map.node(withID: a.id)?.manualPosition != nil)
        undo.undo()
        undo.undo()
        undo.undo()
        #expect(!model.map.hasManualPosition())
    }

    @Test func reparentClearsManualPositionInSameStep() throws {
        let undo = UndoTests.makeUndoManager()
        var a = Node(text: "a")
        a.manualPosition = CGPoint(x: 300, y: 0)
        let b = Node(text: "b")
        let floating = FloatingTopic(node: Node(text: "f"), position: CGPoint(x: 0, y: 300))
        let model = MindMapModel(map: MindMap(root: Node(text: "r", children: [a, b]), floatingTopics: [floating]))
        #expect(model.reparent(a.id, to: b.id, undoManager: undo))
        #expect(model.map.node(withID: a.id)?.manualPosition == nil)
        undo.undo()
        #expect(model.map.parentID(of: a.id) == model.root.id)
        #expect(model.map.node(withID: a.id)?.manualPosition == CGPoint(x: 300, y: 0))
        // Across trees (into a floating topic) too.
        #expect(model.reparent(a.id, to: floating.id, undoManager: undo))
        #expect(model.map.node(withID: a.id)?.manualPosition == nil)
        undo.undo()
        #expect(model.map.node(withID: a.id)?.manualPosition != nil)
    }

    @Test func manualPositionRoundTripsThroughJSON() throws {
        var child = Node(text: "c")
        child.manualPosition = CGPoint(x: -12.5, y: 40)
        let map = MindMap(root: Node(text: "r", children: [child]))
        let decoded = try MindMapPackage.decode(MindMapPackage.encode(map))
        #expect(decoded == map)
        #expect(decoded.root.children[0].manualPosition == CGPoint(x: -12.5, y: 40))
        // Old files without the field, and garbage values, decode as nil.
        let json = """
        {"root": {"id": "\(UUID().uuidString)", "children": [
          {"id": "\(UUID().uuidString)", "text": "x"},
          {"id": "\(UUID().uuidString)", "text": "y", "manualPosition": "bad"}]}}
        """
        let legacy = try MindMapPackage.decode(Data(json.utf8))
        #expect(legacy.root.children.allSatisfy { $0.manualPosition == nil })
    }

    @MainActor
    @Test func editorDropOnEmptySpaceSetsFreePosition() throws {
        let undo = UndoTests.makeUndoManager()
        let a = Node(text: "a"), b = Node(text: "b")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap,
                                                                                    children: [a, b]))))
        editor.undoManager = undo
        editor.updateViewSize(CGSize(width: 800, height: 600))
        let frame = try #require(editor.scene.layout.frames[a.id])
        let start = editor.viewport.toScreen(CGPoint(x: frame.midX, y: frame.midY))
        let translation = CGSize(width: 0, height: 250)
        editor.updateDrag(a.id, translation: translation,
                          location: CGPoint(x: start.x, y: start.y + translation.height))
        #expect(editor.drag?.targetID == nil)
        editor.endDrag()
        let position = try #require(editor.model.map.node(withID: a.id)?.manualPosition)
        #expect(approx(position.y, frame.midY + 250 / editor.viewport.scale, 0.5))
        #expect(editor.isFreelyPositioned(a.id))
        // Zero translation (click without movement) never sets a position.
        editor.updateDrag(b.id, translation: .zero, location: start)
        editor.drag?.targetID = nil
        editor.endDrag()
        #expect(editor.model.map.node(withID: b.id)?.manualPosition == nil)
    }
}
