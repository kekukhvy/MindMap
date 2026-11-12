import SwiftUI
import Testing
@testable import MindMap

/// Reference snapshot of link icons (web, topic, broken, with attachments,
/// floating topic). On macOS the PNG is written to the app container temp
/// dir as `links.png` (copy to Tools/preview/).
@MainActor
struct LinkSnapshotTests {
    static func sampleMap() -> MindMap {
        let palette = ColorTheme.rainbowPalette
        let target = Node(text: "Q3 Roadmap")
        var docs = Node(text: "Docs", customColor: palette[0])
        docs.link = .web(URL(string: "https://developer.apple.com/documentation/swiftui")!)
        var plan = Node(text: "Plan", customColor: palette[1], children: [target])
        plan.link = .topic(UUID()) // broken: target deleted
        var see = Node(text: "See roadmap")
        see.link = .topic(target.id)
        see.attachments = [Attachment(kind: .markdown, title: "Note")]
        let research = Node(text: "Research", customColor: palette[2], children: [see, Node(text: "Interviews")])
        var free = Node(text: "Inbox")
        free.link = .topic(target.id)
        var root = Node(text: "Launch", children: [docs, plan, research])
        root.link = .web(URL(string: "https://example.com")!)
        return MindMap(root: root, floatingTopics: [FloatingTopic(node: free, position: CGPoint(x: -260, y: 150))])
    }

    @Test func renderLinkIconsSnapshot() throws {
        let editor = EditorController(model: MindMapModel(map: LinkSnapshotTests.sampleMap()))
        let size = CGSize(width: 1000, height: 420)
        editor.updateViewSize(size)
        let bounds = editor.scene.layout.bounds
        editor.viewport = Viewport(scale: 1, offset: CGPoint(x: (size.width / 2 - bounds.midX).rounded(),
                                                             y: (size.height / 2 - bounds.midY).rounded()))
        // A jump was made: the Back pill is visible.
        editor.navigationHistory.push(editor.model.root.id)
        let view = CanvasView(editor: editor).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 2000)
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("links.png")
        try data.write(to: url)
        print("SNAPSHOT \(url.path)")
        #endif
    }

    /// WP10: map-link icons (whole map, at a topic) next to web / topic links.
    @Test func renderMapLinkIconsSnapshot() throws {
        let palette = ColorTheme.rainbowPalette
        var roadmap = Node(text: "Roadmap", customColor: palette[0])
        roadmap.link = .map(MapReference(relativePath: "Roadmap.mindmap"))
        var budget = Node(text: "Budget 2027")
        budget.link = .map(MapReference(relativePath: "Finance/Budget.mindmap", targetTopicID: UUID()))
        var hiring = Node(text: "Hiring plan")
        hiring.link = .map(MapReference(relativePath: "../HR/Hiring.mindmap"))
        hiring.attachments = [Attachment(kind: .markdown, title: "Note")]
        let finance = Node(text: "Finance", customColor: palette[1], children: [budget, hiring])
        var site = Node(text: "Website", customColor: palette[2])
        site.link = .web(URL(string: "https://example.com")!)
        var free = Node(text: "Archive")
        free.link = .map(MapReference(relativePath: "Archive.mindmap"))
        let map = MindMap(root: Node(text: "Company", children: [roadmap, finance, site]),
                          floatingTopics: [FloatingTopic(node: free, position: CGPoint(x: -300, y: 140))])
        let editor = EditorController(model: MindMapModel(map: map))
        let size = CGSize(width: 1000, height: 420)
        editor.updateViewSize(size)
        let bounds = editor.scene.layout.bounds
        editor.viewport = Viewport(scale: 1, offset: CGPoint(x: (size.width / 2 - bounds.midX).rounded(),
                                                             y: (size.height / 2 - bounds.midY).rounded()))
        #expect(editor.scene.nodes[budget.id]?.link?.systemImage == "map")
        let view = CanvasView(editor: editor).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 2000)
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-links.png")
        try data.write(to: url)
        print("SNAPSHOT \(url.path)")
        #endif
    }
}
