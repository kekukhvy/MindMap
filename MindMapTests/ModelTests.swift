import Foundation
import Testing
@testable import MindMap

struct ModelTests {
    private func sample() -> Node {
        TestTree.node("root", children: [
            TestTree.node("a", children: [TestTree.node("a1"), TestTree.node("a2")]),
            TestTree.node("b")
        ])
    }

    @Test func addChildAndSibling() throws {
        var root = sample()
        let a = root.children[0].id
        let child = Node(text: "new")
        try root.addChild(child, to: a)
        #expect(root.children[0].children.last?.id == child.id)
        let sibling = Node(text: "sib")
        try root.addSibling(sibling, after: root.children[0].children[0].id)
        #expect(root.children[0].children.map(\.text) == ["a1", "sib", "a2", "new"])
        #expect(throws: TreeEditError.cannotAddSiblingToRoot) { try root.addSibling(after: root.id) }
    }

    @Test func addChildExpandsCollapsedParent() throws {
        var root = sample()
        try root.toggleCollapse(root.children[0].id)
        try root.addChild(to: root.children[0].id)
        #expect(root.children[0].isCollapsed == false)
    }

    @Test func deleteRemovesSubtreeButNotRoot() throws {
        var root = sample()
        let inverse = try root.delete(root.children[0].id)
        #expect(root.subtreeCount == 2)
        #expect(throws: TreeEditError.cannotRemoveRoot) { try root.delete(root.id) }
        try root.apply(inverse)
        #expect(root.subtreeCount == 5)
        #expect(root.children.map(\.text) == ["a", "b"])
    }

    @Test func reparentValidAndInvalid() throws {
        var root = sample()
        let a = root.children[0], b = root.children[1]
        try root.reparent(b.id, to: a.children[0].id)
        #expect(root.node(withID: a.children[0].id)?.children.first?.id == b.id)
        #expect(root.children.count == 1)

        #expect(throws: TreeEditError.invalidMoveTarget) { try root.reparent(a.id, to: a.id) }
        #expect(throws: TreeEditError.invalidMoveTarget) { try root.reparent(a.id, to: b.id) }
        #expect(throws: TreeEditError.cannotMoveRoot) { try root.reparent(root.id, to: a.id) }
        #expect(throws: TreeEditError.nodeNotFound) { try root.reparent(a.id, to: UUID()) }
    }

    @Test func reparentWithinSameParentReorders() throws {
        var root = sample()
        let original = root
        let inverses = try root.reparent(root.children[0].id, to: root.id)
        #expect(root.children.map(\.text) == ["b", "a"])
        try root.apply(inverses)
        #expect(root == original)
    }

    @Test func collapseRenameColorStyleShape() throws {
        var root = sample()
        let a = root.children[0].id
        try root.toggleCollapse(a)
        #expect(root.visibleIDs.count == 3)
        #expect(root.isVisible(root.children[0].children[0].id) == false)
        try root.rename(a, to: "Alpha")
        try root.apply(.setColor(id: a, .blue))
        try root.setLayoutStyle(.treeDown, for: a)
        #expect(root.children[0].text == "Alpha")
        #expect(root.children[0].colorTag == .blue)
        #expect(root.children[0].layoutStyle == .treeDown)
    }

    @Test func navigation() {
        let root = sample()
        let a = root.children[0], b = root.children[1]
        #expect(root.parentID(of: a.id) == root.id)
        #expect(root.parentID(of: root.id) == nil)
        #expect(root.firstVisibleChildID(of: a.id) == a.children[0].id)
        #expect(root.nextSiblingID(of: a.id) == b.id)
        #expect(root.previousSiblingID(of: a.id) == nil)
        #expect(root.selectionAfterDeleting(b.id) == a.id)
        #expect(root.selectionAfterDeleting(a.children[0].id) == a.children[1].id)
        var collapsed = root
        collapsed.children[0].isCollapsed = true
        #expect(collapsed.firstVisibleChildID(of: a.id) == nil)
    }

    @Test func branchShapeAndBorderEdits() throws {
        let root = sample()
        let edits = try root.setAttributeEdits(.shape(.capsule), for: root.children[0].id, wholeBranch: true)
        #expect(edits.count == 3)
        #expect(try root.setAttributeEdits(.borderStyle(.dashed), for: root.id).count == 1)
        #expect(NodeShape.defaultShape(forDepth: 0) == .plainText)
        #expect(NodeShape.defaultShape(forDepth: 1) == .roundedRect)
        #expect(NodeShape.defaultShape(forDepth: 2) == .roundedRect)
        #expect(NodeShape.defaultShape(forDepth: 3) == .plainText)
    }
}
