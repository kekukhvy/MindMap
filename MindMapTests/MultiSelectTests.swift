import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import MindMap

/// Fixture: root(rightMap: a(a1, a2, a3), b(b1, b2, b3), c).
private struct Fixture {
    let a = UUID(), a1 = UUID(), a2 = UUID(), a3 = UUID()
    let b = UUID(), b1 = UUID(), b2 = UUID(), b3 = UUID(), c = UUID()
    let rootID = UUID()

    var map: MindMap {
        MindMap(root: Node(id: rootID, text: "Central", layoutStyle: .rightMap, children: [
            Node(id: a, text: "A", children: [Node(id: a1, text: "A1"), Node(id: a2, text: "A2"),
                                              Node(id: a3, text: "A3")]),
            Node(id: b, text: "B", children: [Node(id: b1, text: "B1"), Node(id: b2, text: "B2"),
                                              Node(id: b3, text: "B3")]),
            Node(id: c, text: "C")
        ]))
    }

    func editor() -> (EditorController, UndoManager) {
        let editor = EditorController(model: MindMapModel(map: map))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        return (editor, undo)
    }
}

/// Undo of exactly one step restores `before` and leaves nothing else.
private func expectOneStep(_ undo: UndoManager, _ model: MindMapModel, restores before: MindMap) {
    #expect(undo.canUndo)
    undo.undo()
    #expect(model.map == before)
    #expect(!undo.canUndo)
}

struct SelectionLogicTests {
    @Test func commandClickTogglesAndMovesPrimary() {
        let f = Fixture()
        let (editor, _) = f.editor()
        editor.clickTopic(f.a1)
        editor.clickTopic(f.b2, command: true)
        #expect(editor.selectedIDs == [f.a1, f.b2])
        #expect(editor.selectedID == f.b2)
        editor.clickTopic(f.c, command: true)
        #expect(editor.selectedIDs == [f.a1, f.b2, f.c] && editor.selectedID == f.c)
        // Removing the primary hands focus to the last remaining (document order).
        editor.clickTopic(f.c, command: true)
        #expect(editor.selectedIDs == [f.a1, f.b2] && editor.selectedID == f.b2)
        editor.clickTopic(f.a1, command: true)
        #expect(editor.selectedIDs == [f.b2] && editor.selectedID == f.b2)
        // Plain click collapses to one topic.
        editor.clickTopic(f.a1, command: true)
        editor.clickTopic(f.c)
        #expect(editor.selectedIDs == [f.c] && editor.selectedID == f.c)
    }

    @Test func shiftClickSelectsSiblingRangeElseAdds() {
        let f = Fixture()
        let (editor, _) = f.editor()
        editor.clickTopic(f.a1)
        editor.clickTopic(f.a3, shift: true)
        #expect(editor.selectedIDs == [f.a1, f.a2, f.a3])
        #expect(editor.selectedID == f.a3)
        // Not a sibling of the primary: just added.
        editor.clickTopic(f.b2, shift: true)
        #expect(editor.selectedIDs == [f.a1, f.a2, f.a3, f.b2])
        #expect(MarqueeSelection.siblingRange(from: f.b3, to: f.b1, in: f.map) == [f.b1, f.b2, f.b3])
        #expect(MarqueeSelection.siblingRange(from: f.a1, to: f.b1, in: f.map) == nil)
    }

    @Test func selectAllAndEscapeKeepPrimary() {
        let f = Fixture()
        let (editor, _) = f.editor()
        editor.select(f.b)
        #expect(editor.perform(.selectAll))
        #expect(editor.selectedIDs.count == 10)
        #expect(editor.selectedID == f.b)
        #expect(editor.commandState.selectionCount == 10)
        #expect(editor.perform(.cancel))
        #expect(editor.selectedIDs == [f.b] && editor.selectedID == f.b)
        #expect(KeyCommandMap.command(key: "a", modifiers: .command, characters: "a") == .selectAll)
        #expect(KeyCommandMap.command(key: "a", modifiers: [.command, .shift], characters: "a") == .attachFile)
        // macOS Backspace arrives as U+007F.
        #expect(KeyCommandMap.command(key: KeyEquivalent("\u{7F}"), modifiers: [], characters: "\u{7f}") == .delete)
    }

    @Test func selectingAnItemOrDeselectingClearsTheSet() {
        let f = Fixture()
        let (editor, _) = f.editor()
        editor.setSelection([f.a, f.b], primary: f.a)
        editor.selectItem(.boundary(UUID()))
        #expect(editor.selectedIDs.isEmpty && editor.selectedID == nil)
        editor.setSelection([f.a, f.b], primary: f.a)
        editor.select(nil)
        #expect(editor.selectedIDs.isEmpty)
    }

    @Test func marqueeHitTestIsIntersectionInDocumentOrder() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let frames = [id1: CGRect(x: 0, y: 0, width: 50, height: 20),
                      id2: CGRect(x: 0, y: 40, width: 50, height: 20),
                      id3: CGRect(x: 200, y: 0, width: 50, height: 20)]
        let order = [id3, id2, id1]
        #expect(MarqueeSelection.hits(in: CGRect(x: 40, y: 10, width: 20, height: 40), frames: frames, order: order)
            == [id2, id1])
        // Drawn from bottom-right to top-left works the same.
        let rect = MarqueeSelection.rect(from: CGPoint(x: 60, y: 50), to: CGPoint(x: 40, y: 10))
        #expect(MarqueeSelection.hits(in: rect, frames: frames, order: order) == [id2, id1])
        #expect(MarqueeSelection.hits(in: CGRect(x: 100, y: 100, width: 5, height: 5), frames: frames,
                                      order: order).isEmpty)
    }

    @Test func editorMarqueeAddsToTheSelectionLive() throws {
        let f = Fixture()
        let (editor, _) = f.editor()
        editor.updateViewSize(CGSize(width: 1200, height: 800))
        editor.select(f.c)
        let a1 = try #require(editor.scene.layout.frames[f.a1]), a2 = try #require(editor.scene.layout.frames[f.a2])
        let start = editor.viewport.toScreen(CGPoint(x: a1.minX - 5, y: a1.minY - 3))
        let end = editor.viewport.toScreen(CGPoint(x: a2.midX, y: a2.midY))
        editor.updateMarquee(from: start, to: end)
        #expect(editor.marquee != nil)
        #expect(editor.selectedIDs == [f.c, f.a1, f.a2])
        #expect(editor.selectedID == f.c)
        // Shrinking the band drops topics it no longer touches (base kept).
        editor.updateMarquee(from: start, to: editor.viewport.toScreen(CGPoint(x: a1.midX, y: a1.midY)))
        #expect(editor.selectedIDs == [f.c, f.a1])
        editor.endMarquee()
        #expect(editor.marquee == nil)
    }

    @Test func ancestorDedupeForMovesAndDeletes() {
        let f = Fixture()
        let map = f.map
        #expect(map.movableTopics([f.a1, f.a, f.b2, f.rootID]) == [f.a, f.b2])
        #expect(map.normalizedTopics([f.b2, f.a3, UUID()]) == [f.a3, f.b2])
        #expect(map.documentOrder([f.c, f.a1, f.a]) == [f.a, f.a1, f.c])
    }

    @Test func targetsAreTheSelectionOnlyForSelectedTopics() {
        let f = Fixture()
        let (editor, _) = f.editor()
        editor.setSelection([f.b1, f.a1], primary: f.a1)
        #expect(editor.targets(for: f.b1) == [f.a1, f.b1])
        #expect(editor.targets(for: f.c) == [f.c])
        #expect(editor.targets() == [f.a1, f.b1])
    }
}

struct MultiTopicOperationTests {
    @Test func deleteSelectionIsOneUndoStep() {
        let f = Fixture()
        let (editor, undo) = f.editor()
        let before = editor.model.map
        // a2 inside the selected a: only a counts.
        editor.setSelection([f.a, f.a2, f.b3], primary: f.b3)
        #expect(editor.perform(.delete))
        #expect(editor.model.map.node(withID: f.a) == nil && editor.model.map.node(withID: f.b3) == nil)
        #expect(editor.model.map.node(withID: f.b2) != nil)
        #expect(editor.selectedID == f.rootID)
        #expect(undo.undoActionName == "Delete Topics")
        expectOneStep(undo, editor.model, restores: before)
    }

    @Test func deleteSelectionCleansRelationshipsAndBoundaries() {
        let f = Fixture()
        var map = f.map
        map.relationships = [Relationship(from: f.a1, to: f.b1)]
        map.boundaries = [Boundary(memberIDs: [f.a1, f.b1]), Boundary(memberIDs: [f.a1])]
        let model = MindMapModel(map: map)
        let undo = UndoTests.makeUndoManager()
        #expect(model.delete([f.a1, f.b1], undoManager: undo))
        #expect(model.map.relationships.isEmpty && model.map.boundaries.isEmpty)
        expectOneStep(undo, model, restores: map)
        // Only one member gone: the boundary shrinks.
        #expect(model.delete([f.b1, f.c], undoManager: undo))
        #expect(model.map.boundaries.map(\.memberIDs) == [[f.a1], [f.a1]])
    }

    @Test func reparentSelectionKeepsRelativeOrder() {
        let f = Fixture()
        let model = MindMapModel(map: f.map)
        let undo = UndoTests.makeUndoManager()
        let before = model.map
        #expect(model.reparent([f.b3, f.a1, f.b1], to: f.c, undoManager: undo))
        #expect(model.map.node(withID: f.c)?.children.map(\.id) == [f.a1, f.b1, f.b3])
        expectOneStep(undo, model, restores: before)
        // Into a descendant of a moving topic: skipped, the rest still moves.
        #expect(model.reparent([f.a, f.b1], to: f.a2, undoManager: undo))
        #expect(model.map.parentID(of: f.a) == f.rootID && model.map.parentID(of: f.b1) == f.a2)
    }

    @Test func insertSelectionBeforeAndAfterSibling() {
        let f = Fixture()
        let model = MindMapModel(map: f.map)
        let undo = UndoTests.makeUndoManager()
        let before = model.map
        #expect(model.insert([f.b3, f.a1], beside: f.b1, after: false, undoManager: undo))
        #expect(model.map.node(withID: f.b)?.children.map(\.id) == [f.a1, f.b3, f.b1, f.b2])
        expectOneStep(undo, model, restores: before)
        #expect(model.insert([f.b1, f.a2, f.c], beside: f.b2, after: true, undoManager: undo))
        // Document order of the moved topics is a2 (in A) before b1 before c.
        #expect(model.map.node(withID: f.b)?.children.map(\.id) == [f.b2, f.a2, f.b1, f.c, f.b3])
        #expect(model.map.node(withID: f.rootID)?.children.map(\.id) == [f.a, f.b])
    }

    @Test func moveTopicsFreelyIsOneStep() {
        let f = Fixture()
        var map = f.map
        let floating = Node(text: "F")
        map.floatingTopics = [FloatingTopic(node: floating, position: CGPoint(x: 0, y: 400))]
        let model = MindMapModel(map: map)
        let undo = UndoTests.makeUndoManager()
        #expect(model.moveTopics([(f.a1, CGPoint(x: 100, y: 50)), (floating.id, CGPoint(x: 30, y: 420))],
                                 undoManager: undo))
        #expect(model.map.node(withID: f.a1)?.manualPosition == CGPoint(x: 100, y: 50))
        #expect(model.map.floatingTopic(floating.id)?.position == CGPoint(x: 30, y: 420))
        expectOneStep(undo, model, restores: map)
    }

    @Test func formatCollapseAndTasksOnSelection() {
        let f = Fixture()
        let (editor, undo) = f.editor()
        let before = editor.model.map
        editor.setSelection([f.a, f.b2], primary: f.a)
        editor.setAttribute(.shape(.capsule), for: f.b2, actionName: "Change Shape")
        #expect(editor.model.map.node(withID: f.a)?.shape == .capsule)
        #expect(editor.model.map.node(withID: f.b2)?.shape == .capsule)
        expectOneStep(undo, editor.model, restores: before)

        editor.setLayoutStyle(.treeDown, for: f.a)
        #expect(editor.model.map.node(withID: f.b2)?.layoutStyle == .treeDown)
        undo.undo()

        editor.setSelection([f.a, f.b], primary: f.a)
        #expect(editor.perform(.toggleCollapse))
        #expect(editor.model.map.node(withID: f.a)?.isCollapsed == true)
        #expect(editor.model.map.node(withID: f.b)?.isCollapsed == true)
        undo.undo()
        editor.validateSelection()

        editor.setSelection([f.a1, f.b1], primary: f.a1)
        editor.convertToTask(f.a1)
        #expect(editor.model.map.node(withID: f.b1)?.task != nil)
        editor.toggleTargetsDone(f.a1)
        #expect(editor.model.map.node(withID: f.a1)?.task?.isDone == true)
        #expect(editor.model.map.node(withID: f.b1)?.task?.isDone == true)
        undo.undo()
        undo.undo()
        #expect(editor.model.map == before)
        #expect(!undo.canUndo)

        editor.setSelection([f.a1, f.b1], primary: f.a1)
        editor.resetColor(f.a1, wholeBranch: false)
        #expect(!undo.canUndo || undo.undoActionName == "Reset Color")
    }
}

struct MultiMemberBoundaryTests {
    @Test func boundaryFromSelectionAndEditMembers() throws {
        let f = Fixture()
        let (editor, undo) = f.editor()
        editor.updateViewSize(CGSize(width: 1200, height: 800))
        editor.setSelection([f.a3, f.b1, f.rootID], primary: f.b1)
        #expect(editor.perform(.addBoundary))
        let boundary = try #require(editor.model.map.boundaries.first)
        #expect(boundary.memberIDs == [f.a3, f.b1])
        #expect(editor.selectedItem == .boundary(boundary.id))
        #expect(undo.undoActionName == "Add Boundary")

        editor.beginEditBoundaryMembers(boundary.id)
        #expect(editor.boundaryMemberEditing == boundary.id)
        #expect(editor.selectedIDs == [f.a3, f.b1])
        // Taps toggle while editing members.
        editor.clickTopic(f.b1)
        editor.clickTopic(f.c)
        editor.finishEditBoundaryMembers(commit: true)
        #expect(editor.model.map.boundaries.first?.memberIDs == [f.a3, f.c])
        #expect(editor.selectedItem == .boundary(boundary.id))
        undo.undo()
        #expect(editor.model.map.boundaries.first?.memberIDs == [f.a3, f.b1])

        // Removing every member removes the boundary (undo restores it).
        editor.beginEditBoundaryMembers(boundary.id)
        editor.clickTopic(f.a3)
        editor.clickTopic(f.b1)
        editor.finishEditBoundaryMembers(commit: true)
        #expect(editor.model.map.boundaries.isEmpty)
        undo.undo()
        #expect(editor.model.map.boundaries.first?.memberIDs == [f.a3, f.b1])

        // Cancel keeps the members.
        editor.beginEditBoundaryMembers(boundary.id)
        editor.clickTopic(f.a3)
        #expect(editor.perform(.cancel))
        #expect(editor.boundaryMemberEditing == nil)
        #expect(editor.model.map.boundaries.first?.memberIDs == [f.a3, f.b1])
    }

    @Test func legacyBoundaryJSONMigratesToMembers() throws {
        let id = UUID(), node = UUID(), sibling = UUID()
        let legacy = #"{"id":"\#(id)","nodeID":"\#(node)","siblingIDs":["\#(sibling)"],"label":"L"}"#
        let decoded = try JSONDecoder().decode(Boundary.self, from: Data(legacy.utf8))
        #expect(decoded.memberIDs == [node, sibling])
        #expect(decoded.label == "L")
        let single = #"{"id":"\#(id)","nodeID":"\#(node)"}"#
        #expect(try JSONDecoder().decode(Boundary.self, from: Data(single.utf8)).memberIDs == [node])

        // New files keep "nodeID" (first member) for older app versions.
        let encoded = try JSONEncoder().encode(Boundary(id: id, memberIDs: [sibling, node], colorHex: "#112233"))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["memberIDs"] as? [String] == [sibling.uuidString, node.uuidString])
        #expect(object["nodeID"] as? String == sibling.uuidString)
        #expect(object["siblingIDs"] == nil)
        #expect(try JSONDecoder().decode(Boundary.self, from: encoded) == Boundary(id: id, memberIDs: [sibling, node],
                                                                                   colorHex: "#112233"))
    }

    @Test func mapJSONRoundTripWithCrossBranchBoundary() throws {
        let f = Fixture()
        var map = f.map
        map.boundaries = [Boundary(memberIDs: [f.a1, f.b3], label: "Zone", colorHex: "#E8524A")]
        let decoded = try MindMapPackage.decode(MindMapPackage.encode(map))
        #expect(decoded == map)
        #expect(decoded.boundaries[0].memberIDs == [f.a1, f.b3])
    }

    @Test func crossBranchOutlineEnclosesMembersAndAvoidsOthers() throws {
        let f = Fixture()
        var map = f.map
        let boundary = Boundary(memberIDs: [f.a1, f.b3], label: "Zone")
        map.boundaries = [boundary]
        let size = CGSize(width: 90, height: 28)
        let layout = TreeLayout().layout(map) { _ in size }
        let outline = try #require(layout.boundaries[boundary.id])
        #expect(!outline.isRectangle)
        for id in [f.a1, f.b3] {
            let frame = try #require(layout.frames[id])
            for corner in [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                           CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)] {
                #expect(outline.contains(corner))
            }
        }
        // Topics between the two members are not enclosed (at most a neck crosses them).
        for id in [f.a2, f.a3, f.b1, f.b2, f.a, f.b, f.c, f.rootID] {
            let frame = try #require(layout.frames[id])
            #expect(!outline.contains(CGPoint(x: frame.midX, y: frame.midY)))
        }
        // Label tab at the first member's top-left, inside the outline.
        let a1 = try #require(layout.frames[f.a1])
        #expect(outline.labelOrigin.y < a1.minY && outline.labelOrigin.x < a1.minX)
        #expect(outline.contains(CGPoint(x: outline.labelOrigin.x + 2, y: outline.labelOrigin.y + 2)))
        // Members reserve padding: no topic overlaps another.
        #expect(TestTree.overlappingPairs(layout.frames) == 0)
    }

    @Test func adjacentMembersGiveOneRectangle() throws {
        let f = Fixture()
        var map = f.map
        // Last child of A + first child of B: nothing else between them.
        let boundary = Boundary(memberIDs: [f.a3, f.b1])
        map.boundaries = [boundary]
        let layout = TreeLayout().layout(map) { _ in CGSize(width: 90, height: 28) }
        let outline = try #require(layout.boundaries[boundary.id])
        #expect(outline.isRectangle)
        #expect(outline.bounds.contains(layout.frames[f.a3]!) && outline.bounds.contains(layout.frames[f.b1]!))
        #expect(!outline.bounds.intersects(layout.frames[f.a2]!) && !outline.bounds.intersects(layout.frames[f.b2]!))
    }

    @Test func hiddenMembersAndNestedBoundaries() throws {
        let f = Fixture()
        var map = f.map
        let outer = Boundary(memberIDs: [f.a, f.b1])
        let inner = Boundary(memberIDs: [f.a2])
        map.boundaries = [outer, inner]
        let layout = TreeLayout().layout(map) { _ in CGSize(width: 90, height: 28) }
        let innerOutline = try #require(layout.boundaries[inner.id])
        let outerOutline = try #require(layout.boundaries[outer.id])
        #expect(outerOutline.bounds.contains(innerOutline.bounds))
        // Collapsing B hides b1: the outline is just around A's subtree.
        try map.root.apply(.setCollapsed(id: f.b, true))
        let collapsed = TreeLayout().layout(map) { _ in CGSize(width: 90, height: 28) }
        let shrunk = try #require(collapsed.boundaries[outer.id])
        #expect(shrunk.isRectangle)
        #expect(!shrunk.bounds.intersects(collapsed.frames[f.b]!))
    }
}

struct BoundaryHullTests {
    @Test func farPiecesAreJoinedAroundAnObstacle() throws {
        let top = CGRect(x: 0, y: 0, width: 120, height: 40)
        let bottom = CGRect(x: 0, y: 200, width: 120, height: 40)
        let obstacle = CGRect(x: 30, y: 100, width: 90, height: 30)
        let outline = try #require(BoundaryHull.outline(pieces: [top, bottom], obstacles: [obstacle]))
        #expect(outline.polygon.count > 4)
        for piece in [top, bottom] {
            #expect(outline.contains(CGPoint(x: piece.minX, y: piece.minY)))
            #expect(outline.contains(CGPoint(x: piece.maxX, y: piece.maxY)))
        }
        #expect(!outline.contains(CGPoint(x: obstacle.midX, y: obstacle.midY)))
        // The neck runs through the free strip left of the obstacle.
        #expect((-20...26).contains { outline.contains(CGPoint(x: CGFloat($0), y: 115)) })
        #expect(BoundaryHull.signedArea(outline.polygon) > 0)
    }

    @Test func freeBoxGivesARectangleAndDiagonalPiecesConnect() throws {
        let a = CGRect(x: 0, y: 0, width: 50, height: 50)
        let b = CGRect(x: 100, y: 100, width: 50, height: 50)
        #expect(try #require(BoundaryHull.outline(pieces: [a, b], obstacles: [])).isRectangle)
        let blocker = CGRect(x: 60, y: 60, width: 30, height: 30)
        let outline = try #require(BoundaryHull.outline(pieces: [a, b], obstacles: [blocker]))
        #expect(!outline.isRectangle)
        #expect(outline.contains(CGPoint(x: 1, y: 1)) && outline.contains(CGPoint(x: 149, y: 149)))
        #expect(!outline.contains(CGPoint(x: blocker.midX, y: blocker.midY)))
        // One closed outline (union traced as a single loop).
        #expect(BoundaryHull.unionOutline(BoundaryHull.neck(between: a, and: b, obstacles: [blocker], width: 20)
            + [a, b]) != nil)
    }

    @Test func unionOutlineOfAnLShape() throws {
        let polygon = try #require(BoundaryHull.unionOutline([CGRect(x: 0, y: 0, width: 100, height: 20),
                                                               CGRect(x: 0, y: 0, width: 20, height: 100)]))
        #expect(polygon.count == 6)
        #expect(approx(BoundaryHull.signedArea(polygon), 100 * 20 + 20 * 80))
        let path = BoundaryHull.roundedPath(polygon, radius: 8)
        #expect(path.boundingBox.width <= 100.5 && path.boundingBox.height <= 100.5)
        #expect(path.contains(CGPoint(x: 10, y: 90)) && !path.contains(CGPoint(x: 90, y: 90)))
    }

    @Test func hitTestFollowsTheOutline() throws {
        let top = CGRect(x: 0, y: 0, width: 120, height: 40)
        let bottom = CGRect(x: 0, y: 200, width: 120, height: 40)
        let outline = try #require(BoundaryHull.outline(pieces: [top, bottom],
                                                        obstacles: [CGRect(x: 30, y: 100, width: 90, height: 30)]))
        #expect(CanvasHitTester.boundaryHits(CGPoint(x: 120, y: 20), outline: outline, hasLabel: false,
                                             tolerance: 4, labelHeight: 20))
        // Inside the bounding box but away from the outline (the obstacle area): no hit.
        #expect(!CanvasHitTester.boundaryHits(CGPoint(x: 80, y: 115), outline: outline, hasLabel: false,
                                              tolerance: 4, labelHeight: 20))
    }
}
