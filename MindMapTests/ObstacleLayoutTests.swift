import CoreGraphics
import Foundation
import Testing
@testable import MindMap

/// Auto-laid subtrees move out of the way of freely positioned ones
/// (`ObstacleAvoidance`): no topic of another branch may overlap them.
@MainActor
struct ObstacleLayoutTests {
    /// The user's map (screenshot 2026-11-12): "Services" was free-moved to
    /// (231.5, 120.5) from the central topic and holds 15 children in a
    /// logic-right column; three main topics stay auto-laid (one with a
    /// child), all lines rounded elbows.
    static func screenshotMap(servicesStyle: LayoutStyle = .rightMap) -> (MindMap, services: UUID) {
        var kids = (0..<15).map { Node(text: $0 == 0 ? "gts-lseg-trade" : $0 == 1 ? "gts-fx-importer" : "Subtopic") }
        kids[0].children = [Node(text: "Subtopic")]
        kids[14].text = "gts-markitserv"
        let services = Node(text: "Services", layoutStyle: servicesStyle,
                            manualPosition: CGPoint(x: 231.5, y: 120.5), children: kids)
        let root = Node(text: "Central Topic", connectorStyle: .roundedElbow, children: [
            services, Node(text: "Main Topic"), Node(text: "Main Topic", children: [Node(text: "Subtopic")]),
            Node(text: "Main Topic"),
        ])
        return (MindMap(root: root), services.id)
    }

    /// Pairs of overlapping topic frames, except a free subtree over its
    /// own ancestors (the user put it there; nothing can move).
    static func overlaps(_ map: MindMap, _ frames: [UUID: CGRect]) -> [(String, String)] {
        var fixed: [UUID: Set<UUID>] = [:]  // manual topic -> its ancestors
        func visit(_ node: Node, ancestors: [UUID]) {
            if node.manualPosition != nil {
                for id in node.allIDs { fixed[id, default: []].formUnion(ancestors) }
            }
            for child in node.children { visit(child, ancestors: ancestors + [node.id]) }
        }
        visit(map.root, ancestors: [])
        let ids = Array(frames.keys)
        var result: [(String, String)] = []
        for i in ids.indices {
            for j in ids.indices where j > i {
                let a = ids[i], b = ids[j]
                if fixed[a]?.contains(b) == true || fixed[b]?.contains(a) == true { continue }
                if frames[a]!.insetBy(dx: 0.01, dy: 0.01).intersects(frames[b]!.insetBy(dx: 0.01, dy: 0.01)) {
                    result.append((map.node(withID: a)?.text ?? "?", map.node(withID: b)?.text ?? "?"))
                }
            }
        }
        return result
    }

    @Test(arguments: [LayoutStyle.rightMap, .treeDown])
    func screenshotSituationHasNoOverlaps(style: LayoutStyle) throws {
        let (map, services) = ObstacleLayoutTests.screenshotMap(servicesStyle: style)
        let scene = MapScene.build(map: map, measurer: NodeMeasurer(), editing: nil)
        let frames = scene.layout.frames
        #expect(ObstacleLayoutTests.overlaps(map, frames).isEmpty, "\(ObstacleLayoutTests.overlaps(map, frames))")
        // Services stays exactly where the user dropped it.
        let root = try #require(frames[map.root.id]), moved = try #require(frames[services])
        #expect(approx(moved.midX - root.midX, 231.5) && approx(moved.midY - root.midY, 120.5))
        // Its whole branch is clear of the other branches (with a gap).
        let node = try #require(map.node(withID: services))
        let branch = node.allIDs.compactMap { frames[$0] }.reduce(CGRect.null) { $0.union($1) }
        for id in frames.keys where !node.allIDs.contains(id) && id != map.root.id {
            #expect(!frames[id]!.intersects(branch), "\(map.node(withID: id)?.text ?? "")")
        }
        // Connectors still end on their (moved) topics.
        for connector in scene.layout.connectors {
            let child = try #require(frames[connector.childID])
            #expect(child.insetBy(dx: -1, dy: -1).contains(connector.end))
        }
    }

    @Test func withoutManualTopicsLayoutIsUnchanged() {
        var (map, _) = ObstacleLayoutTests.screenshotMap()
        map.root.children[0].manualPosition = nil
        let size: (UUID) -> CGSize = { _ in CGSize(width: 90, height: 30) }
        let result = TreeLayout().layout(map, size: size)
        #expect(TestTree.overlappingPairs(result.frames) == 0)
    }

    /// A topic dropped onto the middle of a sibling column: the siblings
    /// before it move up, the others down; the dropped one stays put.
    @Test func siblingsMakeRoomAroundDroppedTopic() throws {
        var root = TestTree.node("root", style: .rightMap, children: TestTree.leaves(6))
        let size = CGSize(width: 100, height: 40)
        let before = TreeLayout().layout(root) { _ in size }
        let target = try #require(before.frames[root.children[2].id])
        // Drop c5 right on top of c2 (offset from the root center).
        root.children[5].manualPosition = CGPoint(x: target.midX + 5, y: target.midY + 3)
        let after = TreeLayout().layout(root) { _ in size }
        #expect(TestTree.overlappingPairs(after.frames) == 0)
        let dropped = try #require(after.frames[root.children[5].id])
        #expect(approx(dropped.midX, target.midX + 5) && approx(dropped.midY, target.midY + 3))
        // Every auto-laid sibling clears it by the root gap; some above, some below.
        let gap = LayoutSpacing().rootVertical
        let column = (0..<5).compactMap { after.frames[root.children[$0].id] }
        for frame in column {
            #expect(frame.maxY <= dropped.minY - gap + 0.01 || frame.minY >= dropped.maxY + gap - 0.01)
        }
        #expect(column.contains { $0.maxY < dropped.minY } && column.contains { $0.minY > dropped.maxY })
        // Order of the auto-laid column is kept.
        for (upper, lower) in zip(column, column.dropFirst()) { #expect(upper.maxY < lower.minY) }
    }

    /// A free topic deep inside one branch pushes the other main branches.
    @Test func deepManualTopicPushesOtherBranches() throws {
        let size = CGSize(width: 100, height: 40)
        var root = TestTree.node("root", style: .rightMap, children: [
            Node(text: "a", children: TestTree.leaves(2, prefix: "a")), Node(text: "b", children: TestTree.leaves(3)),
        ])
        let b = try #require(TreeLayout().layout(root) { _ in size }.frames[root.children[1].children[1].id])
        let a = try #require(TreeLayout().layout(root) { _ in size }.frames[root.children[0].id])
        // a1 (child of a) dropped onto b's middle child.
        root.children[0].children[1].manualPosition = CGPoint(x: b.midX - a.midX, y: b.midY - a.midY)
        let after = TreeLayout().layout(root) { _ in size }
        let found = ObstacleLayoutTests.overlaps(MindMap(root: root), after.frames)
        #expect(found.isEmpty, "\(found)")
    }

    @Test func treeDownChildrenOnlyMoveDown() throws {
        let size = CGSize(width: 100, height: 40)
        var root = TestTree.node("root", style: .treeDown, children: TestTree.leaves(4))
        let before = TreeLayout().layout(root) { _ in size }
        let c1 = try #require(before.frames[root.children[1].id])
        root.children[3].manualPosition = CGPoint(x: c1.midX + 20, y: c1.midY)
        let after = TreeLayout().layout(root) { _ in size }
        #expect(TestTree.overlappingPairs(after.frames) == 0)
        let rootFrame = try #require(after.frames[root.id])
        for child in root.children.prefix(3) {
            #expect(after.frames[child.id]!.minY > rootFrame.maxY)
        }
    }

    @Test func orgChartChildrenMoveSideways() throws {
        let size = CGSize(width: 100, height: 40)
        var root = TestTree.node("root", style: .orgChartDown, children: TestTree.leaves(5))
        let before = TreeLayout().layout(root) { _ in size }
        let c2 = try #require(before.frames[root.children[2].id])
        root.children[4].manualPosition = CGPoint(x: c2.midX + 4, y: c2.midY + 4)
        let after = TreeLayout().layout(root) { _ in size }
        #expect(TestTree.overlappingPairs(after.frames) == 0)
        #expect(approx(after.frames[root.children[2].id]!.minY, c2.minY))
    }

    /// Fuzz: one free topic anywhere in mixed-style trees never overlaps
    /// another branch (except its own ancestors), at many drop positions.
    @Test func randomFreeTopicsNeverOverlapOtherBranches() {
        let styles: [LayoutStyle?] = [.balancedMap, .rightMap, .treeDown, nil, .orgChartDown, .leftMap]
        var failures: [String] = []
        for seed in 0..<6 {
            let tree = TestTree.bushy(depth: 3, branching: 3) { styles[($0 + seed) % styles.count] }
            let sizes = TestTree.sizes(for: tree)
            let candidates = Array(tree.allIDs.dropFirst())
            for (index, id) in candidates.enumerated() where index % 3 == seed % 3 {
                for offset in [CGPoint(x: 160, y: 30), CGPoint(x: -140, y: 90), CGPoint(x: 60, y: -120),
                               CGPoint(x: 220, y: 200)] {
                    var root = tree
                    _ = try? root.apply(.set(id: id, .manualPosition(offset)))
                    let map = MindMap(root: root)
                    let result = TreeLayout().layout(map) { sizes[$0] ?? CGSize(width: 80, height: 30) }
                    let found = ObstacleLayoutTests.overlaps(map, result.frames)
                    if !found.isEmpty { failures.append("seed \(seed) \(offset): \(found.prefix(3))") }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }
}
