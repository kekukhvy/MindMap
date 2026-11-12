import CoreGraphics
import Foundation
import Testing
@testable import MindMap

/// WP2b: curve hit-testing, drop placement / reorder index, undo coalescing,
/// floating topics, relationships and boundaries through the editor.
struct CurveHitTests {
    private let path = RelationshipPath(start: CGPoint(x: 0, y: 0), control1: CGPoint(x: 0, y: -100),
                                        control2: CGPoint(x: 100, y: -100), end: CGPoint(x: 100, y: 0),
                                        labelPoint: CGPoint(x: 50, y: -75))

    @Test func curvedDistanceFollowsTheBezier() {
        // Midpoint of this cubic is (50, -75).
        #expect(RelationshipCurve.distance(from: CGPoint(x: 50, y: -75), to: path, style: .curved) < 0.5)
        #expect(RelationshipCurve.hits(CGPoint(x: 50, y: -70), path: path, style: .curved, tolerance: 8))
        // The chord is far from the curve.
        #expect(!RelationshipCurve.hits(CGPoint(x: 50, y: 0), path: path, style: .curved, tolerance: 8))
        #expect(approx(RelationshipCurve.point(on: path, at: 0.5).y, -75))
    }

    @Test func straightAndElbowDistances() {
        #expect(RelationshipCurve.hits(CGPoint(x: 50, y: 3), path: path, style: .straight, tolerance: 8))
        #expect(approx(RelationshipCurve.distance(from: CGPoint(x: 150, y: 0), to: path, style: .straight), 50))
        let elbow = RelationshipPath(start: .zero, control1: .zero, control2: .zero, end: CGPoint(x: 100, y: 100),
                                     labelPoint: .zero)
        // Vertical segment at mid-x.
        #expect(approx(RelationshipCurve.distance(from: CGPoint(x: 55, y: 50), to: elbow, style: .elbow), 5))
        #expect(RelationshipCurve.polyline(elbow, style: .elbow).count == 4)
    }

    @Test func segmentDistanceClampsToEnds() {
        #expect(approx(RelationshipCurve.segmentDistance(CGPoint(x: -3, y: 4), .zero, CGPoint(x: 10, y: 0)), 5))
        #expect(approx(RelationshipCurve.segmentDistance(CGPoint(x: 1, y: 1), .zero, .zero), sqrt(2)))
    }

    @Test func tangentPointsFallBackWhenDegenerate() {
        let flat = RelationshipPath(start: .zero, control1: .zero, control2: CGPoint(x: 10, y: 0),
                                    end: CGPoint(x: 10, y: 0), labelPoint: .zero)
        let tangents = RelationshipCurve.tangentPoints(flat, style: .curved)
        #expect(tangents.afterStart == CGPoint(x: 10, y: 0))
        #expect(tangents.beforeEnd == .zero)
    }

    @Test func canvasHitTesterPrefersNodesThenLinesThenBoundaries() throws {
        let a = Node(text: "a"), b = Node(text: "b")
        let root = Node(text: "r", layoutStyle: .rightMap, children: [a, b])
        let relationship = Relationship(from: a.id, to: b.id)
        let boundary = Boundary(nodeID: a.id, label: "Group")
        let map = MindMap(root: root, relationships: [relationship], boundaries: [boundary])
        let layout = TreeLayout().layout(map) { _ in CGSize(width: 80, height: 30) }
        let frameA = try #require(layout.frames[a.id])
        #expect(CanvasHitTester.hit(at: CGPoint(x: frameA.midX, y: frameA.midY), layout: layout, map: map,
                                    tolerance: 6) == .node(a.id))
        let curve = try #require(layout.relationships[relationship.id])
        let onCurve = RelationshipCurve.point(on: curve, at: 0.5)
        #expect(CanvasHitTester.hit(at: onCurve, layout: layout, map: map, tolerance: 6)
            == .item(.relationship(relationship.id)))
        let outline = try #require(layout.boundaries[boundary.id])
        let rect = outline.bounds
        #expect(CanvasHitTester.hit(at: CGPoint(x: rect.minX + 1, y: rect.midY), layout: layout, map: map,
                                    tolerance: 6) == .item(.boundary(boundary.id)))
        // Label tab is a hit area; far away is nothing.
        #expect(CanvasHitTester.boundaryHits(CGPoint(x: rect.minX + 30, y: rect.minY + 12), outline: outline,
                                             hasLabel: true, tolerance: 6, labelHeight: 20))
        #expect(!CanvasHitTester.boundaryHits(CGPoint(x: rect.midX, y: rect.midY + 1), outline: outline,
                                              hasLabel: false, tolerance: 2, labelHeight: 20))
        #expect(CanvasHitTester.hit(at: CGPoint(x: 5000, y: 5000), layout: layout, map: map, tolerance: 6) == nil)
    }
}

struct ReorderTests {
    @Test func placementByEdgeZones() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        #expect(DropTargetFinder.placement(at: CGPoint(x: 50, y: 2), in: frame, siblingAxis: .vertical) == .before)
        #expect(DropTargetFinder.placement(at: CGPoint(x: 50, y: 20), in: frame, siblingAxis: .vertical) == .child)
        #expect(DropTargetFinder.placement(at: CGPoint(x: 50, y: 39), in: frame, siblingAxis: .vertical) == .after)
        #expect(DropTargetFinder.placement(at: CGPoint(x: 95, y: 2), in: frame, siblingAxis: .horizontal) == .after)
        #expect(DropTargetFinder.placement(at: CGPoint(x: 50, y: 2), in: frame, siblingAxis: nil) == .child)
    }

    @Test func insertionIndexAccountsForRemovedNode() {
        // Siblings [a, b, c, d]; moving a (0) after c (2) -> index 2 in [b, c, d].
        #expect(DropTargetFinder.insertionIndex(targetIndex: 2, placement: .after, movingIndex: 0) == 2)
        // Moving d (3) before b (1) -> 1.
        #expect(DropTargetFinder.insertionIndex(targetIndex: 1, placement: .before, movingIndex: 3) == 1)
        // From another parent: plain position.
        #expect(DropTargetFinder.insertionIndex(targetIndex: 1, placement: .after, movingIndex: nil) == 2)
        // Before own next sibling = no move.
        #expect(DropTargetFinder.insertionIndex(targetIndex: 2, placement: .before, movingIndex: 1) == 1)
    }

    @Test func dragReordersSiblingsAsOneUndoStep() throws {
        let undo = UndoTests.makeUndoManager()
        let a = Node(text: "a"), b = Node(text: "b"), c = Node(text: "c")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap,
                                                                                    children: [a, b, c]))))
        editor.undoManager = undo
        let frameC = try #require(editor.scene.layout.frames[c.id])
        let below = editor.viewport.toScreen(CGPoint(x: frameC.midX, y: frameC.maxY - 1))
        editor.updateDrag(a.id, translation: .zero, location: below)
        #expect(editor.drag?.targetID == c.id)
        #expect(editor.drag?.placement == .after)
        #expect(editor.drag?.parentTargetID == nil)
        editor.endDrag()
        #expect(editor.model.root.children.map(\.id) == [b.id, c.id, a.id])
        undo.undo()
        #expect(editor.model.root.children.map(\.id) == [a.id, b.id, c.id])
    }
}

struct CoalescingTests {
    @Test func addThenNameIsOneUndoStep() throws {
        let undo = UndoTests.makeUndoManager()
        let editor = EditorController(model: MindMapModel())
        editor.undoManager = undo
        let original = editor.model.map
        editor.select(editor.model.root.id)
        editor.addChild()
        let id = try #require(editor.editingID)
        editor.draftText = "Named"
        editor.commitEditing()
        #expect(editor.model.map.node(withID: id)?.text == "Named")
        #expect(undo.undoActionName == "Add Topic")
        undo.undo()
        #expect(editor.model.map == original)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(editor.model.map.node(withID: id)?.text == "Named")
    }

    @Test func laterRenameIsSeparateStep() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let id = try #require(model.addChild(to: model.root.id, text: "a", undoManager: undo))
        #expect(model.setColor(id, to: .red, undoManager: undo))
        // Another step intervened: no coalescing.
        #expect(model.rename(id, to: "b", coalescing: true, undoManager: undo))
        undo.undo()
        #expect(model.map.node(withID: id)?.text == "a")
        #expect(model.map.node(withID: id)?.colorTag == .red)
    }

    @Test func noCoalescingAfterUndoRedo() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let id = try #require(model.addChild(to: model.root.id, text: "a", undoManager: undo))
        undo.undo()
        undo.redo()
        #expect(model.rename(id, to: "b", coalescing: true, undoManager: undo))
        undo.undo()
        #expect(model.map.node(withID: id)?.text == "a")
    }

    @Test func floatingTopicCreatedAndNamedInOneStep() throws {
        let undo = UndoTests.makeUndoManager()
        let editor = EditorController(model: MindMapModel())
        editor.undoManager = undo
        editor.updateViewSize(CGSize(width: 800, height: 600))
        editor.addFloatingTopic(at: CGPoint(x: 700, y: 500))
        let id = try #require(editor.editingID)
        #expect(editor.model.map.isFloatingRoot(id))
        #expect(editor.draftText == EditorController.floatingTopicText)
        editor.draftText = "Idea"
        editor.commitEditing()
        let topic = try #require(editor.model.map.floatingTopic(id))
        #expect(topic.node.text == "Idea")
        #expect(approx(topic.position.x, 300) && approx(topic.position.y, 200))
        undo.undo()
        #expect(editor.model.map.floatingTopics.isEmpty)
    }
}

struct CanvasItemEditorTests {
    private func makeEditor() -> (EditorController, UndoManager, Node, Node) {
        let undo = UndoTests.makeUndoManager()
        let a = Node(text: "a"), b = Node(text: "b")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap,
                                                                                    children: [a, b]))))
        editor.undoManager = undo
        return (editor, undo, a, b)
    }

    @Test func relationshipPickSelectDeleteUndo() throws {
        let (editor, undo, a, b) = makeEditor()
        editor.select(a.id)
        #expect(editor.perform(.addRelationship))
        #expect(editor.pickMode == .relationship(from: a.id))
        #expect(editor.perform(.cancel))
        #expect(editor.pickMode == nil)
        editor.beginRelationship(from: a.id)
        #expect(editor.completePick(b.id))
        let relationship = try #require(editor.model.map.relationships.first)
        #expect(relationship.fromNodeID == a.id && relationship.toNodeID == b.id)
        #expect(editor.selectedItem == .relationship(relationship.id))
        #expect(editor.commandState.hasSelection && !editor.commandState.hasNodeSelection)

        editor.setLabel("  depends on ", for: .relationship(relationship.id))
        #expect(editor.relationship(relationship.id)?.label == "depends on")
        editor.updateRelationshipStyle(relationship.id) { $0.endArrow = .diamond }
        #expect(editor.relationship(relationship.id)?.style.endArrow == .diamond)

        editor.perform(.delete)
        #expect(editor.model.map.relationships.isEmpty)
        #expect(editor.selectedItem == nil)
        undo.undo()
        #expect(editor.relationship(relationship.id)?.style.endArrow == .diamond)
        undo.undo()
        undo.undo()
        #expect(editor.relationship(relationship.id)?.label == nil)
        undo.undo()
        #expect(editor.model.map.relationships.isEmpty)
    }

    @Test func controlHandleDragIsOneUndoStep() throws {
        let (editor, undo, a, b) = makeEditor()
        let id = try #require(editor.model.addRelationship(from: a.id, to: b.id, undoManager: undo))
        let before = try #require(editor.relationshipPath(id))
        editor.selectItem(.relationship(id))
        editor.updateControlDrag(id, isStart: true, translation: CGSize(width: 40, height: 0))
        editor.updateControlDrag(id, isStart: true, translation: CGSize(width: 60, height: -20))
        let preview = try #require(editor.relationshipPath(id))
        #expect(approx(preview.control1.x, before.control1.x + 60))
        editor.endControlDrag()
        let stored = try #require(editor.relationship(id))
        #expect(stored.fromControlOffset != nil && stored.toControlOffset != nil)
        let after = try #require(editor.relationshipPath(id))
        #expect(approx(after.control1.x, before.control1.x + 60) && approx(after.control1.y, before.control1.y - 20))
        #expect(approx(after.control2.x, before.control2.x))
        undo.undo()
        #expect(editor.relationship(id)?.fromControlOffset == nil)
        #expect(editor.relationship(id) != nil)
    }

    @Test func boundaryCreateLabelColorDelete() throws {
        let (editor, undo, a, _) = makeEditor()
        editor.select(a.id)
        #expect(editor.perform(.addBoundary))
        let boundary = try #require(editor.model.map.boundaries.first)
        #expect(boundary.memberIDs == [a.id])
        #expect(editor.selectedItem == .boundary(boundary.id))
        editor.setLabel("Scope", for: .boundary(boundary.id))
        editor.setBoundaryColor("#E8524A", for: boundary.id)
        #expect(editor.boundary(boundary.id)?.label == "Scope")
        #expect(editor.boundaryColorHex(editor.boundary(boundary.id)!) == "#E8524A")
        editor.perform(.delete)
        #expect(editor.model.map.boundaries.isEmpty)
        undo.undo()
        #expect(editor.boundary(boundary.id)?.colorHex == "#E8524A")
        // No boundary around the central topic.
        editor.select(editor.model.root.id)
        editor.perform(.addBoundary)
        #expect(editor.model.map.boundaries.count == 1)
    }

    @Test func detachAndAttachFloating() throws {
        let (editor, undo, a, b) = makeEditor()
        editor.detachAsFloating(a.id)
        #expect(editor.model.map.isFloatingRoot(a.id))
        editor.beginAttach(a.id)
        #expect(editor.pickMode == .attach(a.id))
        editor.completePick(b.id)
        #expect(editor.model.map.parentID(of: a.id) == b.id)
        undo.undo()
        #expect(editor.model.map.isFloatingRoot(a.id))
        undo.undo()
        #expect(editor.model.map.parentID(of: a.id) == editor.model.root.id)
    }

    @Test func floatingDragMovesInOneStep() throws {
        let (editor, undo, _, _) = makeEditor()
        let id = try #require(editor.model.addFloating(at: CGPoint(x: 0, y: 400), text: "f", undoManager: undo))
        let frame = try #require(editor.scene.layout.frames[id])
        let start = editor.viewport.toScreen(CGPoint(x: frame.midX, y: frame.midY))
        for step in 1...5 {
            let t = CGSize(width: CGFloat(step) * 20, height: 0)
            editor.updateDrag(id, translation: t, location: CGPoint(x: start.x + t.width, y: start.y + 300))
        }
        editor.endDrag()
        #expect(approx(editor.model.map.floatingTopic(id)!.position.x, 100))
        undo.undo()
        #expect(approx(editor.model.map.floatingTopic(id)!.position.x, 0))
    }

    @Test func escapeAndShortcutKeysMap() {
        #expect(KeyCommandMap.command(key: .escape, modifiers: [], characters: "\u{1b}") == .cancel)
        #expect(KeyCommandMap.command(key: "b", modifiers: .command, characters: "b") == .addBoundary)
        #expect(KeyCommandMap.command(key: "l", modifiers: .command, characters: "l") == .addRelationship)
    }
}
