import CoreGraphics
import Foundation
import Testing
@testable import MindMap

struct LayoutStyleTests {
    let size = CGSize(width: 100, height: 40)
    let spacing = LayoutSpacing()

    private func layout(_ root: Node, sizes: [UUID: CGSize]? = nil) -> TreeLayout.Result {
        TreeLayout(spacing: spacing).layout(root) { sizes?[$0] ?? size }
    }

    @Test func balancedMapSplitsAndMirrors() throws {
        let root = TestTree.node("root", children: TestTree.leaves(4))
        let result = layout(root)
        let parent = try #require(result.frames[root.id])
        let right = root.children.prefix(2).compactMap { result.frames[$0.id] }
        let left = root.children.suffix(2).compactMap { result.frames[$0.id] }
        // The central topic uses the wider root gap.
        for f in right { #expect(approx(f.minX, parent.maxX + spacing.rootHorizontal)) }
        for f in left { #expect(approx(f.maxX, parent.minX - spacing.rootHorizontal)) }
        // Mirror symmetry for equal sizes.
        for (r, l) in zip(right, left) {
            #expect(approx(r.minX - parent.maxX, parent.minX - l.maxX))
            #expect(approx(r.midY, l.midY))
        }
        let leftConnector = try #require(result.connectors.first { $0.childID == root.children[3].id })
        #expect(leftConnector.start == CGPoint(x: parent.minX, y: parent.midY))
        #expect(leftConnector.end.x == left[1].maxX)
        #expect(TestTree.overlappingPairs(result.frames) == 0)
    }

    @Test func balancedMapUsesSubtreeHeightNotCount() {
        let big = TestTree.node("big", children: TestTree.leaves(6))
        let root = TestTree.node("root", children: [big] + TestTree.leaves(3))
        let result = layout(root)
        let rootFrame = result.frames[root.id]!
        #expect(result.frames[big.id]!.minX > rootFrame.maxX)
        for leaf in root.children.dropFirst() { #expect(result.frames[leaf.id]!.maxX < rootFrame.minX) }
    }

    @Test func leftSideDescendantsInheritLeftDirection() {
        let deep = TestTree.node("deep", children: [TestTree.node("x", children: TestTree.leaves(2))])
        let root = TestTree.node("root", children: [TestTree.node("r"), deep])
        let result = layout(root)
        let deepFrame = result.frames[deep.id]!
        let xFrame = result.frames[deep.children[0].id]!
        #expect(xFrame.maxX < deepFrame.minX)
        for leaf in deep.children[0].children { #expect(result.frames[leaf.id]!.maxX < xFrame.minX) }
    }

    @Test func leftMapPutsAllChildrenLeft() {
        let root = TestTree.node("root", style: .leftMap, children: TestTree.leaves(3))
        let result = layout(root)
        let parent = result.frames[root.id]!
        for child in root.children { #expect(approx(result.frames[child.id]!.maxX, parent.minX - spacing.rootHorizontal)) }
    }

    @Test func treeDownStacksIndentedBelow() throws {
        let root = TestTree.node("root", style: .treeDown, children: TestTree.leaves(3))
        let result = layout(root)
        let parent = try #require(result.frames[root.id])
        let kids = root.children.compactMap { result.frames[$0.id] }
        for kid in kids { #expect(approx(kid.minX, parent.minX + spacing.treeIndent)) }
        #expect(approx(kids[0].minY, parent.maxY + spacing.levelGap))
        #expect(approx(kids[1].minY, kids[0].maxY + spacing.rootVertical))
        let c = try #require(result.connectors.first { $0.childID == root.children[2].id })
        #expect(c.style == .elbow)
        #expect(c.startAxis == .vertical && c.endAxis == .horizontal)
        #expect(c.start == CGPoint(x: parent.minX + spacing.treeIndent / 2, y: parent.maxY))
        #expect(c.end == CGPoint(x: kids[2].minX, y: kids[2].midY))
    }

    @Test func treeDownOnLeftSideIndentsLeftwards() throws {
        let services = TestTree.node("Services", style: .treeDown, children: TestTree.leaves(2))
        let root = TestTree.node("root", style: .leftMap, children: [services])
        let result = layout(root)
        let s = try #require(result.frames[services.id])
        for leaf in services.children {
            #expect(approx(result.frames[leaf.id]!.maxX, s.maxX - spacing.treeIndent))
        }
        let c = try #require(result.connectors.first { $0.childID == services.children[0].id })
        #expect(c.start.x == s.maxX - spacing.treeIndent / 2)
    }

    @Test func orgChartRowCenteredBelow() throws {
        let root = TestTree.node("root", style: .orgChartDown, children: TestTree.leaves(3))
        let result = layout(root)
        let parent = try #require(result.frames[root.id])
        let kids = root.children.compactMap { result.frames[$0.id] }
        for kid in kids { #expect(approx(kid.minY, parent.maxY + spacing.levelGap)) }
        #expect(approx((kids[0].minX + kids[2].maxX) / 2, parent.midX))
        #expect(approx(kids[1].minX, kids[0].maxX + spacing.rowGap))
        let c = try #require(result.connectors.first)
        #expect(c.style == .elbow)
        #expect(c.startAxis == .vertical && c.endAxis == .vertical)
        #expect(c.start == CGPoint(x: parent.midX, y: parent.maxY))
    }

    @Test func mixedStylesServicesExample() throws {
        let override = TestTree.node("API", style: .rightMap, children: TestTree.leaves(3, prefix: "api"))
        let services = TestTree.node("Services", style: .treeDown,
                                     children: [TestTree.node("Auth"), override, TestTree.node("Billing")])
        let root = TestTree.node("root", children: [services, TestTree.node("Other", children: TestTree.leaves(2))])
        let sizes = TestTree.sizes(for: root)
        let result = layout(root, sizes: sizes)

        #expect(result.frames.count == root.subtreeCount)
        #expect(TestTree.overlappingPairs(result.frames) == 0)
        let rootFrame = result.frames[root.id]!
        let s = result.frames[services.id]!
        #expect(s.minX > rootFrame.maxX)
        // Services children go down, indented.
        let serviceKids = services.children.compactMap { result.frames[$0.id] }
        for kid in serviceKids {
            #expect(approx(kid.minX, s.minX + spacing.treeIndent))
            #expect(kid.minY > s.maxY)
        }
        #expect(serviceKids[0].maxY < serviceKids[1].minY && serviceKids[1].maxY < serviceKids[2].minY)
        // API overrides with a right map.
        let api = result.frames[override.id]!
        for leaf in override.children { #expect(approx(result.frames[leaf.id]!.minX, api.maxX + spacing.horizontal)) }
        let edgeKinds = Dictionary(uniqueKeysWithValues: result.connectors.map { ($0.childID, $0.style) })
        #expect(edgeKinds[services.id] == .curved)
        #expect(edgeKinds[override.id] == .elbow)
        #expect(edgeKinds[override.children[0].id] == .curved)
    }

    @Test func noOverlapAcrossRandomStyleMixes() {
        let styles: [LayoutStyle?] = [nil, .balancedMap, .rightMap, .leftMap, .treeDown, .orgChartDown]
        for seed in 0..<styles.count * 3 {
            let root = TestTree.bushy(depth: 4, branching: 3) { level in styles[(seed + level * 5) % styles.count] }
            let sizes = TestTree.sizes(for: root)
            let result = layout(root, sizes: sizes)
            #expect(result.frames.count == root.subtreeCount)
            #expect(TestTree.overlappingPairs(result.frames) == 0, "seed \(seed)")
        }
    }
}
