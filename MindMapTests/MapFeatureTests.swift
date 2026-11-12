import CoreGraphics
import Foundation
import Testing
@testable import MindMap

struct ColorThemeTests {
    private func map() -> MindMap {
        MindMap(root: TestTree.node("root", children: [
            TestTree.node("a", children: [TestTree.node("a1")]),
            TestTree.node("b", children: [Node(text: "b1", customColor: "#000000")]),
            Node(text: "c", colorTag: .gray)
        ]), floatingTopics: [FloatingTopic(node: Node(text: "f"), position: CGPoint(x: 0, y: 300))])
    }

    @Test func rainbowAssignsBranchColorsAndInherits() {
        let map = map()
        let colors = ColorResolver.effectiveColors(in: map)
        let palette = ColorTheme.rainbowPalette
        let a = map.root.children[0], b = map.root.children[1], c = map.root.children[2]
        #expect(colors[map.root.id] == ColorTheme.rainbow.rootHex)
        #expect(colors[a.id] == palette[0])
        #expect(colors[a.children[0].id] == palette[0])
        #expect(colors[b.id] == palette[1])
        #expect(colors[b.children[0].id] == "#000000") // custom override
        #expect(colors[c.id] == ColorTag.gray.hex)      // tag override
        #expect(colors[map.floatingTopics[0].id] == palette[3])
    }

    @Test func monoThemeAndUndoableSetTheme() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel(map: map())
        #expect(model.setTheme(.mono(hex: "#123456"), undoManager: undo))
        let a = model.root.children[0]
        #expect(ColorResolver.effectiveColor(of: a.children[0].id, in: model.map) == "#123456")
        #expect(ColorResolver.effectiveColor(of: model.root.id, in: model.map) == "#123456")
        undo.undo()
        #expect(model.map.theme == .rainbow)
    }

    @Test func customColorOnBranchIsOneUndoStep() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel(map: map())
        let a = model.root.children[0]
        #expect(model.setCustomColor("#ABCDEF", for: a.id, wholeBranch: true, undoManager: undo))
        let colors = ColorResolver.effectiveColors(in: model.map)
        #expect(colors[a.id] == "#ABCDEF" && colors[a.children[0].id] == "#ABCDEF")
        undo.undo()
        #expect(model.map.node(withID: a.children[0].id)?.customColor == nil)
        #expect(model.map.node(withID: a.id)?.customColor == nil)
    }
}

struct FloatingTopicTests {
    @Test func addMoveDeleteWithUndo() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let f = try #require(model.addFloating(at: CGPoint(x: 200, y: 200), text: "F", undoManager: undo))
        let child = try #require(model.addChild(to: f, text: "fc", undoManager: undo))
        #expect(model.map.floatingTopics.first?.node.children.first?.id == child)
        #expect(model.moveFloating(f, to: CGPoint(x: 10, y: 20), undoManager: undo))
        #expect(model.map.floatingTopic(f)?.position == CGPoint(x: 10, y: 20))
        #expect(model.addSibling(after: f, undoManager: undo) == nil)
        #expect(model.delete(f, undoManager: undo))
        #expect(model.map.floatingTopics.isEmpty)
        undo.undo()
        undo.undo()
        #expect(model.map.floatingTopic(f)?.position == CGPoint(x: 200, y: 200))
        #expect(model.map.node(withID: child) != nil)
    }

    @Test func attachIntoTreeAndDetachBack() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let a = try #require(model.addChild(to: model.root.id, text: "a", undoManager: undo))
        let f = try #require(model.addFloating(at: .zero, text: "F", undoManager: undo))
        let fc = try #require(model.addChild(to: f, undoManager: undo))
        #expect(model.reparent(f, to: fc, undoManager: undo) == false) // into own subtree
        #expect(model.reparent(f, to: a, undoManager: undo))
        #expect(model.map.floatingTopics.isEmpty)
        #expect(model.root.parentID(of: f) == a)
        #expect(model.root.parentID(of: fc) == f)

        #expect(model.detach(a, to: CGPoint(x: 0, y: 400), undoManager: undo))
        #expect(model.root.children.isEmpty)
        #expect(model.map.floatingTopic(a)?.node.contains(fc) == true)
        #expect(model.detach(model.root.id, to: .zero, undoManager: undo) == false)

        undo.undo()
        #expect(model.root.parentID(of: a) == model.root.id)
        undo.undo()
        #expect(model.map.floatingTopic(f) != nil)
        #expect(model.root.contains(f) == false)
    }

    @Test func layoutIncludesFloatingTopics() throws {
        let child = Node(text: "fc")
        let floating = FloatingTopic(node: Node(text: "F", children: [child]), position: CGPoint(x: 0, y: 500))
        let map = MindMap(root: TestTree.node("root", children: TestTree.leaves(2)), floatingTopics: [floating])
        let result = TreeLayout().layout(map) { _ in CGSize(width: 100, height: 40) }
        let f = try #require(result.frames[floating.id])
        #expect(f.midX == 0 && f.midY == 500)
        let c = try #require(result.frames[child.id])
        #expect(c.minX == f.maxX + LayoutSpacing().horizontal) // default rightMap
        #expect(result.connectors.contains { $0.parentID == floating.id && $0.childID == child.id })
        #expect(result.frames.count == 5)
    }
}

struct RelationshipTests {
    @Test func addRelabelRemoveAndInvalid() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let a = try #require(model.addChild(to: model.root.id, undoManager: undo))
        let f = try #require(model.addFloating(at: CGPoint(x: 0, y: 300), undoManager: undo))
        #expect(model.addRelationship(from: a, to: a, undoManager: undo) == nil)
        #expect(model.addRelationship(from: a, to: UUID(), undoManager: undo) == nil)
        let r = try #require(model.addRelationship(from: a, to: f, label: "x", undoManager: undo))
        #expect(model.relabelRelationship(r, to: "depends", undoManager: undo))
        #expect(model.map.relationships.first?.label == "depends")
        undo.undo()
        #expect(model.map.relationships.first?.label == "x")
        #expect(model.removeRelationship(r, undoManager: undo))
        #expect(model.map.relationships.isEmpty)
        undo.undo()
        #expect(model.map.relationships.count == 1)
    }

    @Test func deletingNodeRemovesRelationshipsAndUndoRestores() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let a = try #require(model.addChild(to: model.root.id, undoManager: undo))
        let a1 = try #require(model.addChild(to: a, undoManager: undo))
        let b = try #require(model.addChild(to: model.root.id, undoManager: undo))
        _ = try #require(model.addRelationship(from: a1, to: b, undoManager: undo))
        let keep = try #require(model.addRelationship(from: model.root.id, to: b, undoManager: undo))
        let before = model.map
        #expect(model.delete(a, undoManager: undo))
        #expect(model.map.relationships.map(\.id) == [keep])
        undo.undo()
        #expect(model.map == before)
        undo.redo()
        #expect(model.map.relationships.map(\.id) == [keep])
    }

    @Test func styleDefaultsAndUndoableSetter() throws {
        let style = RelationshipStyle()
        #expect(style.path == .curved && style.dash == .dashed && style.endArrow == .arrow && style.startArrow == .none)
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let a = try #require(model.addChild(to: model.root.id, undoManager: undo))
        let r = try #require(model.addRelationship(from: model.root.id, to: a, undoManager: undo))
        let newStyle = RelationshipStyle(path: .elbow, dash: .dotted, startArrow: .dot, endArrow: .diamond,
                                         width: 3, colorHex: "#FF0000")
        #expect(model.setRelationshipStyle(newStyle, for: r, undoManager: undo))
        #expect(model.map.relationships[0].style == newStyle)
        #expect(model.setRelationshipControlOffsets(r, from: CGVector(dx: 5, dy: 5), to: nil, undoManager: undo))
        undo.undo()
        undo.undo()
        #expect(model.map.relationships[0].style == RelationshipStyle())
    }

    @Test func geometryAnchorsOnFrames() throws {
        let a = Node(text: "a"), b = Node(text: "b")
        let relationship = Relationship(from: a.id, to: b.id)
        let map = MindMap(root: TestTree.node("root", style: .rightMap, children: [a, b]),
                          relationships: [relationship])
        let result = TreeLayout().layout(map) { _ in CGSize(width: 100, height: 40) }
        let path = try #require(result.relationships[relationship.id])
        let fa = result.frames[a.id]!, fb = result.frames[b.id]!
        // a is above b: anchors on a's bottom edge and b's top edge.
        #expect(approx(path.start.y, fa.maxY) && approx(path.start.x, fa.midX))
        #expect(approx(path.end.y, fb.minY) && approx(path.end.x, fb.midX))
        // Hidden end -> no geometry.
        var collapsed = map
        collapsed.root.isCollapsed = true
        #expect(TreeLayout().layout(collapsed) { _ in CGSize(width: 100, height: 40) }.relationships.isEmpty)
    }
}

struct BoundaryTests {
    let size = CGSize(width: 100, height: 40)

    @Test func boundaryEnclosesSubtreeAndReservesSpace() throws {
        let a = TestTree.node("a", children: TestTree.leaves(2))
        let b = TestTree.node("b")
        let boundary = Boundary(nodeID: a.id, label: "Group")
        let root = TestTree.node("root", style: .rightMap, children: [a, b])
        let plain = TreeLayout().layout(root) { _ in size }
        let result = TreeLayout().layout(MindMap(root: root, boundaries: [boundary])) { _ in size }
        let rect = try #require(result.boundaries[boundary.id])
        let spacing = LayoutSpacing()
        for id in a.allIDs { #expect(rect.contains(result.frames[id]!)) }
        #expect(!rect.intersects(result.frames[b.id]!))
        #expect(!rect.intersects(result.frames[root.id]!))
        let enclosed = a.allIDs.map { result.frames[$0]! }.reduce(CGRect.null) { $0.union($1) }
        #expect(approx(rect.minY, enclosed.minY - spacing.boundaryPadding - spacing.boundaryLabelHeight))
        // b was pushed down to make room.
        #expect(result.frames[b.id]!.minY - result.frames[a.id]!.maxY > plain.frames[b.id]!.minY - plain.frames[a.id]!.maxY)
        #expect(TestTree.overlappingPairs(result.frames) == 0)
    }

    @Test func nestedAndSiblingRangeBoundaries() throws {
        let a = TestTree.node("a", children: TestTree.leaves(2))
        let b = TestTree.node("b", children: TestTree.leaves(1))
        let root = TestTree.node("root", style: .rightMap, children: [a, b, TestTree.node("c")])
        let inner = Boundary(nodeID: a.children[0].id)
        let outer = Boundary(nodeID: a.id, siblingIDs: [b.id])
        let result = TreeLayout().layout(MindMap(root: root, boundaries: [inner, outer])) { _ in size }
        let innerRect = try #require(result.boundaries[inner.id])
        let outerRect = try #require(result.boundaries[outer.id])
        #expect(outerRect.contains(innerRect))
        for id in a.allIDs + b.allIDs { #expect(outerRect.contains(result.frames[id]!)) }
        #expect(!outerRect.contains(result.frames[root.children[2].id]!))
    }

    @Test func boundaryOpsCleanupAndUndo() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let a = try #require(model.addChild(to: model.root.id, undoManager: undo))
        let b = try #require(model.addChild(to: model.root.id, undoManager: undo))
        let a1 = try #require(model.addChild(to: a, undoManager: undo))
        #expect(model.addBoundary(around: a, siblings: [a1], undoManager: undo) == nil) // not a sibling
        let range = try #require(model.addBoundary(around: a, siblings: [b], label: "R", undoManager: undo))
        let single = try #require(model.addBoundary(around: b, undoManager: undo))
        #expect(model.updateBoundary(single, label: "S", colorHex: "#00FF00", undoManager: undo))
        let before = model.map

        #expect(model.delete(b, undoManager: undo))
        #expect(model.map.boundaries.map(\.id) == [range])
        #expect(model.map.boundaries[0].siblingIDs.isEmpty)
        undo.undo()
        #expect(model.map == before)

        #expect(model.delete(a, undoManager: undo))
        #expect(model.map.boundaries.map(\.id) == [single])
        undo.undo()
        #expect(model.map == before)
        #expect(model.removeBoundary(range, undoManager: undo))
        undo.undo()
        #expect(model.map == before)
    }
}

struct ConnectorStyleTests {
    let size = CGSize(width: 100, height: 40)

    @Test func inheritedConnectorStyleAndOverride() throws {
        let deep = TestTree.node("deep", children: TestTree.leaves(1))
        var services = TestTree.node("Services", style: .treeDown, children: [deep])
        let root = Node(text: "root", connectorStyle: .straight, lineWidth: 2, lineDash: .dashed,
                        children: [TestTree.node("a", children: TestTree.leaves(1)), services])
        let result1 = TreeLayout().layout(root) { _ in size }
        let byChild = Dictionary(uniqueKeysWithValues: result1.connectors.map { ($0.childID, $0) })
        #expect(result1.connectors.allSatisfy { $0.style == .straight && $0.lineWidth == 2 && $0.dash == .dashed })
        #expect(byChild[deep.id]?.startAxis == .vertical)

        // Explicit override on Services wins over inherited (and over treeDown's elbow default).
        services.connectorStyle = .roundedElbow
        var root2 = root
        root2.children[1] = services
        let result2 = TreeLayout().layout(root2) { _ in size }
        let byChild2 = Dictionary(uniqueKeysWithValues: result2.connectors.map { ($0.childID, $0) })
        #expect(byChild2[services.id]?.style == .straight)       // edge root->Services uses root's style
        #expect(byChild2[deep.id]?.style == .roundedElbow)
        #expect(byChild2[deep.children[0].id]?.style == .roundedElbow) // inherited
    }

    @Test func defaultsByLayout() {
        let root = TestTree.node("root", children: [
            TestTree.node("t", style: .treeDown, children: TestTree.leaves(1)),
            TestTree.node("o", style: .orgChartDown, children: TestTree.leaves(1))
        ])
        let result = TreeLayout().layout(root) { _ in size }
        let byParent = Dictionary(grouping: result.connectors, by: \.parentID)
        #expect(byParent[root.id]?.allSatisfy { $0.style == .curved && $0.dash == .solid && $0.lineWidth == nil } == true)
        #expect(byParent[root.children[0].id]?.first?.style == .elbow)
        #expect(byParent[root.children[1].id]?.first?.style == .elbow)
    }

    @Test func lineSettersAreUndoable() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let id = model.root.id
        #expect(model.setConnectorStyle(.elbow, for: id, undoManager: undo))
        #expect(model.setLineWidth(3, for: id, undoManager: undo))
        #expect(model.setLineDash(.dotted, for: id, undoManager: undo))
        #expect(model.root.connectorStyle == .elbow && model.root.lineWidth == 3 && model.root.lineDash == .dotted)
        undo.undo(); undo.undo(); undo.undo()
        #expect(model.root.connectorStyle == nil && model.root.lineWidth == nil && model.root.lineDash == nil)
    }
}
