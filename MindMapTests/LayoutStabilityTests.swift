import CoreGraphics
import Foundation
import Testing
@testable import MindMap

/// WP17 layout stability on the "MindMap Features" sample (bundled =
/// committed) and the user's copy of it (everything collapsed, Tasks panel
/// dragged above the map): expanding / collapsing never flips main topics
/// across the central topic, never overlaps anything (topics, boundary
/// outlines and label tabs, the Tasks panel), and keeps the toggled topic
/// still on screen.
@MainActor
struct LayoutStabilityTests {
    static func featuresMap() throws -> MindMap {
        let archive = try SampleMaps.archive(SampleMaps.featuresResource)
        return try MindMapPackage.decode(try #require(archive.files[MindMapPackage.mapFileName]))
    }

    /// The user's copy (Samples/ working tree, 2026-11-13): every topic with
    /// children collapsed except the central one, Tasks panel dragged to
    /// (-125, -504).
    static func userVariant(_ map: MindMap) -> MindMap {
        var map = map
        func collapse(_ node: inout Node) {
            if !node.children.isEmpty { node.isCollapsed = true }
            for index in node.children.indices { collapse(&node.children[index]) }
        }
        for index in map.root.children.indices { collapse(&map.root.children[index]) }
        map.taskPanel = TaskPanelState(position: CGPoint(x: -125, y: -504))
        return map
    }

    /// The user's real file when the test host can read the repo (iPad
    /// simulator; the sandboxed macOS host cannot).
    static func userFile() -> MindMap? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/MindMap Features.mindmap/map.json")
        return (try? Data(contentsOf: url)).flatMap { try? MindMapPackage.decode($0) }
    }

    static func variant(_ name: String) throws -> MindMap? {
        switch name {
        case "committed": return try featuresMap()
        case "user": return userVariant(try featuresMap())
        default: return userFile()
        }
    }

    static func preorder(_ map: MindMap) -> [Node] {
        var result: [Node] = []
        func visit(_ node: Node) {
            result.append(node)
            node.children.forEach(visit)
        }
        visit(map.root)
        map.floatingTopics.forEach { visit($0.node) }
        return result
    }

    /// Editor with a view large enough that "Go to" never needs to scroll.
    static func editor(_ map: MindMap) -> EditorController {
        let editor = EditorController(model: MindMapModel(map: map))
        editor.updateViewSize(CGSize(width: 40_000, height: 40_000))
        return editor
    }

    static func violations(_ editor: EditorController) -> [LayoutAudit.Violation] {
        LayoutAudit.violations(map: editor.model.map, layout: editor.scene.layout, panel: editor.taskPanel?.frame,
                               panelIsFixed: editor.taskPanel?.isAutoPositioned == false)
    }

    /// Side of every main topic as drawn (left of the central topic or not).
    static func drawnSides(_ editor: EditorController) -> [UUID: Bool] {
        let frames = editor.scene.layout.frames
        let root = frames[editor.model.map.root.id] ?? .zero
        return Dictionary(uniqueKeysWithValues: editor.model.map.root.children.compactMap { child in
            frames[child.id].map { (child.id, $0.midX < root.midX) }
        })
    }

    /// Candidates of one random step: visible topics with children.
    static func toggleCandidates(_ editor: EditorController) -> [Node] {
        let root = editor.model.map.root.id
        return preorder(editor.model.map).filter {
            !$0.children.isEmpty && $0.id != root && editor.scene.nodes[$0.id] != nil
        }
    }

    /// Replays random toggle sequence `sequence` (seed 17, 12 steps each)
    /// on `editor` up to (not including) step `stopBefore`. Picks depend
    /// only on which topics are visible, so the replay is the same whatever
    /// the layout does (used for the snapshot of a case the old layout got
    /// wrong).
    static func replay(_ editor: EditorController, sequence: Int, stopBefore: Int) {
        var rng = SeededGenerator(seed: 17)
        let start = editor.model.map
        for index in 0...sequence {
            let target = index == sequence ? editor : EditorController(model: MindMapModel(map: start))
            for step in 0..<12 {
                guard let pick = toggleCandidates(target).randomElement(using: &rng) else { break }
                if index == sequence && step == stopBefore { return }
                target.toggleCollapse(pick.id)
            }
        }
    }

    /// Runs `action`, then checks the WP17 guarantees: no overlaps, main
    /// topics on the same side (drawn and stored), `anchor` (or its nearest
    /// ancestor visible before and after) still within 1 pt on screen.
    static func check(_ editor: EditorController, anchor: UUID?, _ label: String,
                      _ action: () -> Void) {
        let sides = drawnSides(editor)
        var chain: [UUID] = anchor.map { [$0] } ?? []
        while let last = chain.last, let parent = editor.model.map.parentID(of: last) { chain.append(parent) }
        let frames = editor.scene.layout.frames
        let screen = chain.compactMap { id in frames[id].map { (id, editor.viewport.toScreen($0)) } }
        let mapBefore = editor.model.map
        action()
        let after = editor.scene.layout.frames
        let found = violations(editor)
        #expect(found.isEmpty, "\(label): \(found.prefix(5))")
        #expect(drawnSides(editor) == sides, "\(label): a main topic changed sides")
        // Any edit stores the sides of main topics that had none.
        let unpinned = editor.model.map.root.children.filter { $0.side == nil }
        #expect(editor.model.map == mapBefore || unpinned.isEmpty, "\(label): unpinned main topics")
        if let (id, old) = screen.first(where: { after[$0.0] != nil }), let frame = after[id] {
            let new = editor.viewport.toScreen(frame)
            let delta = hypot(new.minX - old.minX, new.minY - old.minY)
            #expect(delta < 1, "\(label): anchored topic moved \(delta) pt on screen")
        }
    }

    // MARK: Expand / collapse every topic

    @Test(arguments: ["committed", "user", "user-file"])
    func everyTopicOneByOne(variant: String) throws {
        guard let map = try Self.variant(variant) else {
            print("LayoutStability: \(variant) not readable by this test host, skipped")
            return
        }
        print("LayoutStability: \(variant) loaded (\(Self.preorder(map).count) topics)")
        let editor = Self.editor(map)
        #expect(Self.violations(editor).isEmpty)
        // Each topic toggled and back.
        for node in Self.preorder(map) where !node.children.isEmpty && node.id != map.root.id {
            guard editor.scene.nodes[node.id] != nil else { continue }
            Self.check(editor, anchor: node.id, "\(variant) toggle \(node.text)") { editor.toggleCollapse(node.id) }
            Self.check(editor, anchor: node.id, "\(variant) back \(node.text)") { editor.toggleCollapse(node.id) }
        }
        // Cumulative: expand everything one by one (pre-order), then collapse
        // it again bottom-up.
        let all = Self.preorder(map).filter { !$0.children.isEmpty && $0.id != map.root.id }
        for node in all where editor.model.map.node(withID: node.id)?.isCollapsed == true {
            guard editor.scene.nodes[node.id] != nil else { continue }
            Self.check(editor, anchor: node.id, "\(variant) expand \(node.text)") { editor.toggleCollapse(node.id) }
        }
        for node in all.reversed() where editor.model.map.node(withID: node.id)?.isCollapsed == false {
            guard editor.scene.nodes[node.id] != nil else { continue }
            Self.check(editor, anchor: node.id, "\(variant) collapse \(node.text)") { editor.toggleCollapse(node.id) }
        }
    }

    /// 200 random sequences of 12 steps mixing every way to expand /
    /// collapse: toggle, Expand / Collapse Branch, Collapse to Level,
    /// Expand All, Go to (reveal), multi-selection toggle.
    @Test(arguments: ["committed", "user"])
    func randomSequences(variant: String) throws {
        let start = try #require(try Self.variant(variant))
        var rng = SeededGenerator(seed: 2026)
        for sequence in 0..<200 {
            let editor = Self.editor(start)
            for step in 0..<12 {
                let candidates = Self.toggleCandidates(editor)
                guard let pick = candidates.randomElement(using: &rng) else { break }
                let label = "\(variant) #\(sequence).\(step)"
                switch Int.random(in: 0..<10, using: &rng) {
                case 0:
                    Self.check(editor, anchor: pick.id, "\(label) expand branch") { editor.expandBranch(pick.id) }
                case 1:
                    Self.check(editor, anchor: pick.id, "\(label) collapse branch") { editor.collapseBranch(pick.id) }
                case 2:
                    editor.select(pick.id)
                    let level = Int.random(in: 1...4, using: &rng)
                    Self.check(editor, anchor: pick.id, "\(label) level \(level)") { editor.collapseToLevel(level) }
                case 3:
                    editor.select(pick.id)
                    Self.check(editor, anchor: pick.id, "\(label) expand all") { editor.expandAll() }
                case 4:
                    // Go to a hidden topic: its collapsed ancestor stays put.
                    let hidden = Self.preorder(editor.model.map).filter { editor.scene.nodes[$0.id] == nil }
                    guard let target = hidden.randomElement(using: &rng) else { continue }
                    Self.check(editor, anchor: target.id, "\(label) go to") { editor.show(target.id) }
                case 5:
                    let other = candidates.randomElement(using: &rng)!
                    editor.select(pick.id)
                    editor.toggleSelection(other.id)
                    editor.selectedID = pick.id
                    Self.check(editor, anchor: pick.id, "\(label) multi") { editor.toggleCollapseTargets(pick.id) }
                default:
                    Self.check(editor, anchor: pick.id, "\(label) toggle") { editor.toggleCollapse(pick.id) }
                }
            }
        }
    }

    // MARK: Sides

    @Test func sidesSurviveAddDeleteAndUndo() throws {
        let editor = Self.editor(try Self.featuresMap())
        let undo = UndoManager()
        editor.undoManager = undo
        let before = editor.model.map
        let shown = Self.drawnSides(editor)
        // First edit pins the sides shown (legacy file without sides).
        let first = try #require(before.root.children.first { !$0.children.isEmpty })
        editor.toggleCollapse(first.id)
        let pinned = editor.model.map.root.children
        #expect(pinned.allSatisfy { $0.side != nil })
        #expect(Dictionary(uniqueKeysWithValues: pinned.map { ($0.id, $0.side == .left) }) == shown)
        // Undo restores the file exactly (sides included).
        undo.undo()
        #expect(editor.model.map == before)
        undo.redo()
        #expect(editor.model.map.root.children.map(\.side) == pinned.map(\.side))

        // Adding a main topic: the lighter side; nothing else moves.
        let split = editor.scene.layout.balanced[before.root.id]!
        let lighter: BranchSide = split.weight(of: .left) < split.weight(of: .right) ? .left : .right
        editor.select(nil)
        editor.addChild()
        editor.commitEditing()
        let added = try #require(editor.model.map.root.children.last)
        #expect(added.side == lighter)
        #expect(Self.drawnSides(editor).filter { $0.key != added.id } == shown)
        // Deleting a main topic keeps the others.
        editor.select(pinned[1].id)
        editor.deleteSelection()
        #expect(Self.drawnSides(editor).filter { $0.key != added.id } == shown.filter { $0.key != pinned[1].id })
        // A sibling joins its neighbour's side (right after it).
        let leftTopic = try #require(editor.model.map.root.children.first { $0.side == .left })
        editor.select(leftTopic.id)
        editor.addSibling()
        editor.commitEditing()
        let sibling = try #require(editor.selectedID)
        #expect(editor.model.map.node(withID: sibling)?.side == .left)
    }

    @Test func newMapAlternatesSidesByWeight() throws {
        let editor = Self.editor(MindMap(root: Node(text: "Central")))
        for _ in 0..<4 {
            editor.select(nil)
            editor.addChild()
            editor.commitEditing()
        }
        #expect(editor.model.map.root.children.map(\.side) == [.right, .left, .right, .left])
    }

    @Test func rebalanceIsOneUndoStep() throws {
        var map = try Self.featuresMap()
        // Everything on the right: rebalancing must split it.
        for index in map.root.children.indices { map.root.children[index].side = .right }
        let editor = Self.editor(map)
        let undo = UndoManager()
        editor.undoManager = undo
        #expect(Self.drawnSides(editor).values.allSatisfy { !$0 })
        editor.rebalanceMap()
        #expect(undo.undoActionName == "Rebalance Map")
        let sides = editor.model.map.root.children.compactMap(\.side)
        #expect(sides.contains(.left) && sides.contains(.right))
        // Same split as a new map would get from the measured heights.
        let split = editor.scene.layout.balanced[map.root.id]!
        let expected = BalancedSplit.sides(stored: map.root.children.map { _ in nil },
                                           heights: map.root.children.map { split.heights[$0.id]! })
        #expect(sides == expected)
        #expect(Self.violations(editor).isEmpty)
        undo.undo()
        #expect(editor.model.map == map)
    }

    @Test func draggingAcrossTheRootChangesSide() throws {
        let topics = (0..<4).map { Node(text: "Main \($0)", side: $0 < 2 ? .right : .left) }
        let editor = Self.editor(MindMap(root: Node(text: "Central", children: topics)))
        let frames = editor.scene.layout.frames
        let scale = editor.viewport.scale
        // Drop "Main 0" (right) below "Main 3" (left): it joins the left side.
        let source = frames[topics[0].id]!, target = frames[topics[3].id]!
        editor.drag = NodeDrag(id: topics[0].id, movingIDs: [topics[0].id],
                               translation: CGSize(width: (target.midX - source.midX) * scale,
                                                   height: (target.maxY - source.midY) * scale),
                               targetID: topics[3].id, placement: .after)
        editor.endDrag()
        #expect(editor.model.map.node(withID: topics[0].id)?.side == .left)
        #expect(editor.model.map.root.children.map(\.id).last == topics[0].id)
        #expect(editor.scene.layout.frames[topics[0].id]!.midX < 0)
        // Dropped onto the central topic's right half: right side again.
        let root = editor.scene.layout.frames[editor.model.map.root.id]!
        let now = editor.scene.layout.frames[topics[0].id]!
        editor.drag = NodeDrag(id: topics[0].id, movingIDs: [topics[0].id],
                               translation: CGSize(width: (root.maxX - 5 - now.midX) * scale, height: 0),
                               targetID: editor.model.map.root.id, placement: .child)
        // Same parent: a drop "as child" of its own parent is no move.
        editor.endDrag()
        #expect(editor.model.map.node(withID: topics[0].id)?.side == .left)
        // Free move to the right of the central topic: the manual side.
        editor.model.setManualPosition(topics[2].id, to: CGPoint(x: 300, y: 40), undoManager: nil)
        #expect(editor.model.map.node(withID: topics[2].id)?.side == .right)
        editor.model.setManualPosition(topics[2].id, to: nil, undoManager: nil)
        #expect(editor.scene.layout.frames[topics[2].id]!.midX > 0)
        // A topic from elsewhere dropped on the left half of the central topic.
        editor.model.addChild(to: topics[1].id, text: "kid", undoManager: nil)
        let kid = try #require(editor.model.map.node(withID: topics[1].id)?.children.first)
        let kidFrame = editor.scene.layout.frames[kid.id]!
        editor.drag = NodeDrag(id: kid.id, movingIDs: [kid.id],
                               translation: CGSize(width: (root.minX + 5 - kidFrame.midX) * scale, height: 0),
                               targetID: editor.model.map.root.id, placement: .child)
        editor.endDrag()
        #expect(editor.model.map.node(withID: kid.id)?.side == .left)
    }

    @Test func sideIsSavedAndOptional() throws {
        var node = Node(text: "a", side: .left)
        let data = try JSONEncoder().encode(node)
        #expect(String(decoding: data, as: UTF8.self).contains("\"side\":\"left\""))
        #expect(try JSONDecoder().decode(Node.self, from: data).side == .left)
        node.side = nil
        #expect(!String(decoding: try JSONEncoder().encode(node), as: UTF8.self).contains("side"))
        let unknown = #"{"id":"6AB7997A-20D6-4724-A044-24AA04B655DB","side":"up"}"#
        #expect(try JSONDecoder().decode(Node.self, from: Data(unknown.utf8)).side == nil)
    }

    // MARK: Obstacles

    @Test func mainTreeKeepsClearOfFloatingTopicsAndDraggedPanel() throws {
        let kids = (0..<6).map { Node(text: "Child \($0)") }
        let main = Node(text: "Main", side: .right, children: kids)
        var map = MindMap(root: Node(text: "Central", children: [main, Node(text: "Other", side: .left)]))
        map.floatingTopics = [FloatingTopic(node: Node(text: "Floating"), position: CGPoint(x: 260, y: 20))]
        let size = { (_: UUID) in CGSize(width: 90, height: 30) }
        let free = TreeLayout().layout(map, size: size)
        let floating = try #require(free.frames[map.floatingTopics[0].id])
        for kid in kids {
            #expect(!free.frames[kid.id]!.intersects(floating))
        }
        // A dragged panel over the branch pushes it away; it never moves.
        let panel = CGRect(x: 100, y: -200, width: 280, height: 160)
        let result = TreeLayout().layout(map, fixedObstacles: [panel], size: size)
        for id in [main.id] + kids.map(\.id) {
            #expect(!result.frames[id]!.intersects(panel))
            #expect(!result.frames[id]!.intersects(floating))
        }
        #expect(result.frames[map.floatingTopics[0].id] == floating)
        #expect(LayoutAudit.violations(map: map, layout: result, panel: panel).isEmpty)
    }

    @Test func fixedPanelFrameMatchesThePanel() throws {
        var map = try Self.featuresMap()
        map.taskPanel = TaskPanelState(position: CGPoint(x: -125, y: -504))
        for completed in [false, true] {
            for all in [false, true] {
                let content = try #require(TaskPanelLayout.content(map: map, contentBounds: .zero, lingering: [],
                                                                   showsCompleted: completed, showsAll: all,
                                                                   now: Date()))
                #expect(TaskPanelLayout.fixedFrame(map: map, lingering: [], showsCompleted: completed,
                                                   showsAll: all) == content.frame)
            }
        }
        map.taskPanel = nil
        #expect(TaskPanelLayout.fixedFrame(map: map, lingering: [], showsCompleted: false, showsAll: false) == nil)
    }

    /// Random maps mixing every layout style, free topics, boundaries and
    /// floating topics: random toggles never produce an overlap.
    @Test func randomMapsNeverOverlap() throws {
        var rng = SeededGenerator(seed: 99)
        let styles: [LayoutStyle?] = [nil, nil, nil, .rightMap, .leftMap, .treeDown, .orgChartDown]
        var topics = 0, free = 0, checks = 0
        for mapIndex in 0..<60 {
            func make(_ depth: Int) -> Node {
                var node = Node(text: String(repeating: "w", count: Int.random(in: 1...14, using: &rng)),
                                layoutStyle: depth > 0 ? styles.randomElement(using: &rng)! : nil)
                if depth < 3 {
                    node.children = (0..<Int.random(in: 0...(depth == 0 ? 6 : 4), using: &rng)).map { _ in make(depth + 1) }
                }
                if depth > 0, Int.random(in: 0..<12, using: &rng) == 0 {
                    node.manualPosition = CGPoint(x: CGFloat.random(in: -400...400, using: &rng).rounded(),
                                                  y: CGFloat.random(in: -300...300, using: &rng).rounded())
                }
                return node
            }
            var map = MindMap(root: make(0))
            let ids = Self.preorder(map).dropFirst().map(\.id)
            for _ in 0..<2 where !ids.isEmpty {
                map.boundaries.append(Boundary(nodeID: ids.randomElement(using: &rng)!,
                                               label: Bool.random(using: &rng) ? "Group" : nil))
            }
            map.floatingTopics = [FloatingTopic(node: make(2), position: CGPoint(
                x: CGFloat.random(in: -700...700, using: &rng).rounded(),
                y: CGFloat.random(in: -500...500, using: &rng).rounded()))]
            let editor = Self.editor(map)
            #expect(Self.violations(editor).isEmpty, "map \(mapIndex) initial: \(Self.violations(editor).prefix(3))")
            topics += Self.preorder(map).count
            free += Self.preorder(map).filter { $0.manualPosition != nil }.count
            for step in 0..<12 {
                guard let pick = Self.toggleCandidates(editor).randomElement(using: &rng) else { break }
                Self.check(editor, anchor: pick.id, "map \(mapIndex).\(step)") { editor.toggleCollapse(pick.id) }
                checks += 1
            }
        }
        // The fuzz really covers big maps with free topics.
        #expect(topics > 1000 && free > 60 && checks > 500, "\(topics) topics, \(free) free, \(checks) checks")
    }

    // MARK: Determinism / performance

    @Test func sameInputSameLayout() throws {
        let map = Self.userVariant(try Self.featuresMap())
        var expanded = map
        expanded.root = try Self.featuresMap().root
        for input in [map, expanded] {
            let a = MapScene.build(map: input, measurer: NodeMeasurer(), editing: nil,
                                   fixedObstacles: [CGRect(x: -125, y: -504, width: 280, height: 260)]).layout
            let copy = try MindMapPackage.decode(try JSONEncoder().encode(input))
            let b = MapScene.build(map: copy, measurer: NodeMeasurer(), editing: nil,
                                   fixedObstacles: [CGRect(x: -125, y: -504, width: 280, height: 260)]).layout
            #expect(a == b)
        }
        // The same expand / collapse sequence ends in the same picture.
        func run() -> TreeLayout.Result {
            let editor = Self.editor(map)
            for text in ["Hotkeys", "Editing", "Layout Styles", "Known gaps / Roadmap", "Editing"] {
                if let node = Self.preorder(editor.model.map).first(where: { $0.text == text }) {
                    editor.toggleCollapse(node.id)
                }
            }
            return editor.scene.layout
        }
        #expect(run() == run())
    }

    @Test func thousandTopicsStayFast() throws {
        // 1 + 10 + 100 + 900 topics, all expanded.
        let root = Node(text: "Central", children: (0..<10).map { a in
            Node(text: "Main \(a)", children: (0..<10).map { b in
                Node(text: "Topic \(a).\(b)", children: (0..<9).map { Node(text: "Leaf \(a).\(b).\($0)") })
            })
        })
        let map = MindMap(root: root)
        #expect(Self.preorder(map).count == 1011)
        let clock = ContinuousClock()
        let layout = clock.measure {
            _ = TreeLayout().layout(map) { _ in CGSize(width: 110, height: 30) }
        }
        #expect(layout < .milliseconds(500), "layout \(layout)")
        let editor = Self.editor(map)
        _ = editor.scene
        let toggle = clock.measure {
            for main in root.children.prefix(5) {
                editor.toggleCollapse(main.id)
                _ = editor.scene
            }
        }
        #expect(toggle < .seconds(5), "5 toggles \(toggle)")
        #expect(Self.violations(editor).isEmpty)
    }
}

/// Deterministic RNG (SplitMix64) for fuzz tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// Before / after pictures of the worst cases found for WP17 (written to
/// `<tmp>/layout-stability/<case>-<tag>-1-before|2-after.png`; copies in
/// Tools/preview/layout-stability/ as `<case>-1-before`, `-2-after-old`
/// (this suite run on the pre-WP17 commit with `tag = "old"`) and
/// `-3-after-new`). Same view size and starting viewport for both.
@MainActor
struct LayoutStabilitySnapshots {
    static let tag = "new"
    static let size = CGSize(width: 2000, height: 1400)

    struct Scenario {
        var name: String
        var user: Bool
        /// Toggles before the pictured one (texts in pre-order, first match).
        var setup: (EditorController) -> Void = { _ in }
        var toggle: String
    }

    static func id(_ text: String, in map: MindMap) -> UUID? {
        LayoutStabilityTests.preorder(map).first { $0.text == text }?.id
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "user-expand-known-gaps", user: true, toggle: "Known gaps / Roadmap"),
        Scenario(name: "user-expand-hotkeys", user: true, toggle: "Hotkeys"),
        Scenario(name: "committed-collapse-hotkeys", user: false, toggle: "Hotkeys"),
        Scenario(name: "committed-floating", user: false, setup: { editor in
            // Random sequence 108 of the fuzz test before its step 10, which
            // expands "Layout Styles" (old layout: Structure under the
            // floating topic afterwards).
            LayoutStabilityTests.replay(editor, sequence: 108, stopBefore: 10)
        }, toggle: "Layout Styles"),
    ]

    @Test func renderScenarios() throws {
        let base = try LayoutStabilityTests.featuresMap()
        for scenario in Self.scenarios {
            let map = scenario.user ? LayoutStabilityTests.userVariant(base) : base
            let editor = EditorController(model: MindMapModel(map: map))
            editor.updateViewSize(Self.size)
            scenario.setup(editor)
            editor.viewport = .fitting(editor.contentBoundsIncludingPanel, in: Self.size, margin: 60, maxScale: 1)
            let target = try #require(Self.id(scenario.toggle, in: editor.model.map))
            editor.select(target)
            try Self.write(editor, name: "\(scenario.name)-\(Self.tag)-1-before")
            editor.toggleCollapse(target)
            try Self.write(editor, name: "\(scenario.name)-\(Self.tag)-2-after")
        }
    }

    static func write(_ editor: EditorController, name: String) throws {
        let view = CanvasView(editor: editor).frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("layout-stability", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("SNAPSHOT \(url.path)")
    }
}
#endif
