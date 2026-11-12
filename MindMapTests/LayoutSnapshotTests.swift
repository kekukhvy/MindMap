import SwiftUI
import Testing
@testable import MindMap

/// Rendered references of the user's "Services" map (screenshot
/// 2026-11-12): free-moved Services next to the other branches, and
/// Services as a tree chart. On macOS the PNGs are written to the app
/// container temp dir (`services-*.png`; copies in Tools/preview/).
@MainActor
struct LayoutSnapshotTests {
    /// Central topic with Services (9 children, first one with a child)
    /// as a tree chart, plus three other main topics.
    static func treeDownMap() -> (MindMap, services: UUID) {
        var kids = (0..<9).map { Node(text: ["gts-lseg-trade", "gts-fx-importer", "gts-markitserv"][safe: $0] ?? "Subtopic") }
        kids[0].children = [Node(text: "Subtopic")]
        let services = Node(text: "Services", layoutStyle: .treeDown, children: kids)
        let root = Node(text: "Central Topic", children: [
            Node(text: "Main Topic"), services, Node(text: "Main Topic", children: [Node(text: "Subtopic")]),
            Node(text: "Main Topic"),
        ])
        return (MindMap(root: root), services.id)
    }

    @Test func treeDownServicesHangsBelowWithIndentedChildren() throws {
        let (map, services) = LayoutSnapshotTests.treeDownMap()
        let scene = MapScene.build(map: map, measurer: NodeMeasurer(), editing: nil)
        let frames = scene.layout.frames
        let parent = try #require(frames[services])
        let node = try #require(map.node(withID: services))
        var previous = parent
        for child in node.children {
            let frame = try #require(frames[child.id])
            // One under another, starting below Services, indented right.
            #expect(frame.minY > previous.maxY - 0.01)
            #expect(approx(frame.minX, parent.minX + LayoutSpacing().treeIndent, 0.5))
            // Elbow from a rail under the parent's left part to the child's left edge.
            let line = try #require(scene.layout.connectors.first { $0.childID == child.id })
            #expect(line.startAxis == .vertical && line.endAxis == .horizontal)
            #expect(approx(line.start.y, parent.maxY) && line.start.x < parent.minX + parent.width / 3)
            #expect(approx(line.end.x, frame.minX) && approx(line.end.y, frame.midY))
            previous = frames[child.children.first?.id ?? child.id].map { $0.union(frame) } ?? frame
        }
        // Grandchildren extend to the right as usual.
        let first = try #require(frames[node.children[0].id])
        let grandchild = try #require(frames[node.children[0].children[0].id])
        #expect(grandchild.minX > first.maxX && approx(grandchild.midY, first.midY, 0.5))
        #expect(TestTree.overlappingPairs(frames) == 0)
    }

    /// The layout menu action re-lays out the children immediately.
    @Test func choosingTreeDownRelaysOutImmediately() throws {
        let (map, services) = ObstacleLayoutTests.screenshotMap()
        let editor = EditorController(model: MindMapModel(map: map))
        let before = try #require(editor.scene.layout.frames[map.node(withID: services)!.children[5].id])
        editor.select(services)
        editor.setLayoutStyle(.treeDown)
        let parent = try #require(editor.scene.layout.frames[services])
        let after = try #require(editor.scene.layout.frames[map.node(withID: services)!.children[5].id])
        #expect(after != before && after.minY > parent.maxY && after.minX < parent.maxX)
        #expect(editor.model.map.node(withID: services)?.layoutStyle == .treeDown)
    }

    @Test(arguments: ["services-free", "services-tree"])
    func renderReference(name: String) throws {
        let map = name == "services-free" ? ObstacleLayoutTests.screenshotMap().0 : LayoutSnapshotTests.treeDownMap().0
        try LayoutSnapshotTests.render(map, name: name)
    }

    static func render(_ map: MindMap, name: String, configure: (EditorController) -> Void = { _ in }) throws {
        let editor = EditorController(model: MindMapModel(map: map))
        configure(editor)
        let bounds = editor.scene.layout.bounds.insetBy(dx: -30, dy: -30)
        let size = CGSize(width: max(600, bounds.width.rounded(.up)), height: max(400, bounds.height.rounded(.up)))
        editor.updateViewSize(size)
        editor.viewport = Viewport(scale: 1, offset: CGPoint(x: (size.width / 2 - bounds.midX).rounded(),
                                                             y: (size.height / 2 - bounds.midY).rounded()))
        let view = CanvasView(editor: editor).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width > 0)
        #if os(macOS)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("SNAPSHOT \(url.path)")
        #endif
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Reference render of a topic being dragged onto another one.
@MainActor
struct DragPreviewSnapshotTests {
    @Test func renderLiveConnector() throws {
        let a = Node(text: "Alpha"), b = Node(text: "Beta", children: [Node(text: "kid")]), c = Node(text: "Gamma")
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [a, b, c]))
        try LayoutSnapshotTests.render(map, name: "drag-live-line") { editor in
            let frames = editor.scene.layout.frames
            let source = frames[a.id]!, target = frames[c.id]!
            // Alpha held over Gamma's right part (child drop on Gamma), and
            // slightly lower so the line visibly bends.
            let translation = CGSize(width: target.maxX + 60 - source.midX, height: target.midY + 40 - source.midY)
            editor.drag = NodeDrag(id: a.id, translation: translation, targetID: c.id)
            #expect(editor.prospectiveParent(for: editor.drag!) == c.id)
            #expect(editor.dragConnector?.geometry.start.x == target.maxX)
        }
    }
}
