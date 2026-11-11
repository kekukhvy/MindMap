import CoreGraphics
import Foundation
import Testing
@testable import MindMap

struct NavigationTests {
    let size = CGSize(width: 80, height: 30)

    private func navigator(_ root: Node) -> SelectionNavigator {
        SelectionNavigator(layout: TreeLayout().layout(root) { _ in size })
    }

    @Test func rightMapArrows() {
        let a = Node(text: "a", children: TestTree.leaves(2, prefix: "a"))
        let b = Node(text: "b")
        let root = Node(text: "root", layoutStyle: .rightMap, children: [a, b])
        let nav = navigator(root)
        #expect(nav.target(from: root.id, direction: .right) != nil)
        #expect(nav.target(from: a.id, direction: .left) == root.id)
        #expect(nav.target(from: a.id, direction: .down) == b.id)
        #expect(nav.target(from: b.id, direction: .up) == a.id)
        let child = nav.target(from: a.id, direction: .right)
        #expect(a.children.map(\.id).contains(child ?? UUID()))
        #expect(nav.target(from: a.children[0].id, direction: .down) == a.children[1].id)
        // Leaf: nothing further right.
        #expect(nav.target(from: b.id, direction: .right) == nil)
    }

    @Test func leftSideBranchesAreMirrored() {
        let left = Node(text: "left", layoutStyle: .leftMap, children: TestTree.leaves(1))
        let root = Node(text: "root", layoutStyle: .rightMap, children: [left])
        let nav = navigator(root)
        // `left` itself is right of root, its child to its left.
        #expect(nav.target(from: left.id, direction: .left) == root.id)
        let balanced = Node(text: "root", children: [Node(text: "r", children: TestTree.leaves(1)),
                                                     Node(text: "l", children: TestTree.leaves(1))])
        let nav2 = navigator(balanced)
        let l = balanced.children[1]
        #expect(nav2.target(from: l.id, direction: .right) == balanced.id)
        #expect(nav2.target(from: l.id, direction: .left) == l.children[0].id)
        #expect(nav2.target(from: balanced.id, direction: .left) == l.id)
        #expect(nav2.target(from: balanced.id, direction: .right) == balanced.children[0].id)
    }

    @Test func treeDownAndOrgChart() {
        let tree = Node(text: "services", layoutStyle: .treeDown, children: TestTree.leaves(2))
        let org = Node(text: "org", layoutStyle: .orgChartDown, children: TestTree.leaves(2))
        let root = Node(text: "root", layoutStyle: .rightMap, children: [tree, org])
        let nav = navigator(root)
        #expect(nav.target(from: tree.id, direction: .right) == tree.children[0].id)
        #expect(nav.target(from: tree.children[0].id, direction: .left) == tree.id)
        #expect(nav.target(from: tree.children[0].id, direction: .down) == tree.children[1].id)
        #expect(nav.target(from: org.id, direction: .down) != nil)
        #expect(nav.target(from: org.children[0].id, direction: .up) == org.id)
        #expect(nav.target(from: org.children[0].id, direction: .right) == org.children[1].id)
        #expect(nav.target(from: org.children[1].id, direction: .left) == org.children[0].id)
    }

    @Test func cousinFallbackWhenNoSibling() {
        let a = Node(text: "a", children: TestTree.leaves(1, prefix: "a"))
        let b = Node(text: "b", children: TestTree.leaves(1, prefix: "b"))
        let root = Node(text: "root", layoutStyle: .rightMap, children: [a, b])
        let nav = navigator(root)
        #expect(nav.target(from: a.children[0].id, direction: .down) == b.children[0].id)
    }

    @Test func dropTargetHitTesting() {
        let frames: [UUID: CGRect] = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!: CGRect(x: 0, y: 0, width: 100, height: 40),
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!: CGRect(x: 10, y: 10, width: 20, height: 10),
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!: CGRect(x: 300, y: 0, width: 50, height: 20),
        ]
        let big = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let small = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let far = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        #expect(DropTargetFinder.target(at: CGPoint(x: 15, y: 15), frames: frames, excluding: []) == small)
        #expect(DropTargetFinder.target(at: CGPoint(x: 15, y: 15), frames: frames, excluding: [small]) == big)
        #expect(DropTargetFinder.target(at: CGPoint(x: 80, y: 30), frames: frames, excluding: []) == big)
        #expect(DropTargetFinder.target(at: CGPoint(x: 297, y: 10), frames: frames, excluding: []) == far)
        #expect(DropTargetFinder.target(at: CGPoint(x: 200, y: 200), frames: frames, excluding: []) == nil)
    }
}
