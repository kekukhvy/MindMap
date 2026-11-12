import CoreGraphics
import Foundation
import Testing
@testable import MindMap

struct TreeLayoutTests {
    let size = CGSize(width: 100, height: 40)
    let spacing = LayoutSpacing()

    @Test func singleNodeCenteredAtOrigin() {
        let root = Node(text: "root")
        let result = TreeLayout().layout(root) { _ in size }
        #expect(result.frames.count == 1)
        #expect(result.frames[root.id] == CGRect(x: -50, y: -20, width: 100, height: 40))
        #expect(result.connectors.isEmpty)
        #expect(result.bounds == result.frames[root.id])
    }

    @Test func rightMapChildrenCenteredToTheRight() throws {
        let root = TestTree.node("root", style: .rightMap, children: TestTree.leaves(3))
        let result = TreeLayout(spacing: spacing).layout(root) { _ in size }
        let parent = try #require(result.frames[root.id])
        let kids = root.children.compactMap { result.frames[$0.id] }
        #expect(kids.count == 3)
        for kid in kids { #expect(approx(kid.minX, parent.maxX + spacing.rootHorizontal)) }
        #expect(approx((kids[0].midY + kids[2].midY) / 2, parent.midY))
        #expect(kids[0].minY < kids[1].minY && kids[1].minY < kids[2].minY)
        #expect(approx(kids[1].minY - kids[0].maxY, spacing.rootVertical))
        #expect(result.connectors.count == 3)
        let connector = try #require(result.connectors.first { $0.childID == root.children[0].id })
        #expect(connector.style == .curved)
        #expect(connector.startAxis == .horizontal && connector.endAxis == .horizontal)
        #expect(connector.start == CGPoint(x: parent.maxX, y: parent.midY))
        #expect(connector.end == CGPoint(x: kids[0].minX, y: kids[0].midY))
    }

    @Test func noOverlapWithVariableSizes() {
        let root = TestTree.bushy(depth: 4, branching: 4) { $0 == 0 ? .rightMap : nil }
        let sizes = TestTree.sizes(for: root)
        let result = TreeLayout().layout(root) { sizes[$0]! }
        #expect(result.frames.count == root.subtreeCount)
        #expect(TestTree.overlappingPairs(result.frames) == 0)
    }

    @Test func collapseHidesSubtree() {
        var root = TestTree.node("root", children: [
            TestTree.node("a", children: TestTree.leaves(3)),
            TestTree.node("b")
        ])
        root.children[0].isCollapsed = true
        let result = TreeLayout().layout(root) { _ in size }
        #expect(result.frames.count == 3)
        #expect(result.connectors.count == 2)
        for leaf in root.children[0].children { #expect(result.frames[leaf.id] == nil) }
    }

    /// Runs on an 8 MB stack like the app's main thread (Swift Testing's
    /// worker threads have small stacks; layout is recursive per level).
    @Test func deepChainLaysOutWithoutOverlap() {
        let depth = 500
        var chain = Node(text: "\(depth - 1)")
        for level in stride(from: depth - 2, through: 0, by: -1) {
            chain = Node(text: "\(level)", children: [chain])
        }
        let root = chain
        var ids: [UUID] = []
        var cursor: Node? = root
        while let node = cursor { ids.append(node.id); cursor = node.children.first }

        let result = onLargeStack { TreeLayout().layout(root) { _ in size } }
        #expect(result.frames.count == depth)
        #expect(result.connectors.count == depth - 1)
        let xs = ids.compactMap { result.frames[$0]?.minX }
        #expect(xs.count == depth)
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 })
        #expect(TestTree.overlappingPairs(result.frames) == 0)
    }

    @Test func connectorsMatchVisibleEdges() {
        let root = TestTree.bushy(depth: 3, branching: 3)
        let result = TreeLayout().layout(root) { _ in size }
        #expect(result.connectors.count == result.frames.count - 1)
    }
}
