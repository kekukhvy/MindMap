import SwiftUI
import Testing
@testable import MindMap

/// XMind pastel default style: pure checks + a reference snapshot of the
/// user's iPad screenshot map ("Work"). On macOS the PNG is written to the
/// app container temp dir as `xmind-style.png` (copy to Tools/preview/).
@MainActor
struct StyleSnapshotTests {
    /// Root "Work"; right: Main Topic 1, Services -> gts-lseg-fix-conn-svc ->
    /// How connect works, Main Topic 5; left: Main Topic 4, Main Topic 3.
    static func sampleMap() -> MindMap {
        let palette = ColorTheme.rainbowPalette
        func main(_ text: String, _ color: Int, _ children: [Node] = []) -> Node {
            Node(text: text, customColor: palette[color], children: children)
        }
        let services = main("Services", 1, [
            Node(text: "gts-lseg-fix-conn-svc", children: [Node(text: "How connect works")]),
        ])
        return MindMap(root: Node(text: "Work", children: [
            main("Main Topic 1", 0), services, main("Main Topic 5", 4),
            main("Main Topic 4", 2), main("Main Topic 3", 3),
        ]))
    }

    @Test func defaultsMatchXMindPastel() throws {
        let map = StyleSnapshotTests.sampleMap()
        let scene = MapScene.build(map: map, measurer: NodeMeasurer(), editing: nil)
        let root = try #require(scene.nodes[map.root.id]?.appearance)
        #expect(root.shape == .plainText && root.fill == .none && root.weight == .heavy)
        #expect(root.textColorHex == ColorTheme.inkHex && root.fontSize > 1.5 * NodeAppearance.mainFontSize)
        let services = map.root.children[1]
        let main = try #require(scene.nodes[services.id]?.appearance)
        #expect(main.shape == .roundedRect && main.fill == .solid && main.border == nil)
        #expect(main.colorHex == "#F2A16D" && main.textColorHex == ColorTheme.inkHex)
        let level2 = try #require(scene.nodes[services.children[0].id]?.appearance)
        #expect(level2.fill == .tint && level2.border == nil && level2.fontSize < main.fontSize)
        #expect(level2.fillHex == HexColor.tint("#F2A16D", amount: NodeAppearance.tintAmount))
        #expect(level2.textColorHex == HexColor.darkShade("#F2A16D"))
        let level3 = try #require(scene.nodes[services.children[0].children[0].id]?.appearance)
        #expect(level3.shape == .plainText && level3.fill == .none && level3.border == nil)
        #expect(level3.textColorHex == level2.textColorHex)
        // Thin, untapered branch-colored lines; Services is level with the root.
        for connector in scene.connectors {
            #expect(!connector.geometry.isTapered && connector.geometry.startWidth == MapScene.defaultLineWidth)
        }
        let straight = try #require(scene.connectors.first { $0.childID == services.id })
        #expect(straight.colorHex == "#F2A16D" && straight.geometry.startAxis == .horizontal)
        #expect(abs(straight.geometry.start.y - straight.geometry.end.y) < 0.5)
        let curved = try #require(scene.connectors.first { $0.childID == map.root.children[0].id })
        #expect(curved.geometry.startAxis == .vertical && curved.geometry.endAxis == .horizontal)
        // Root gap is wide, deeper gaps narrow.
        let spacing = LayoutSpacing()
        let rootFrame = try #require(scene.layout.frames[map.root.id])
        let servicesFrame = try #require(scene.layout.frames[services.id])
        let level2Frame = try #require(scene.layout.frames[services.children[0].id])
        #expect(abs(servicesFrame.minX - rootFrame.maxX - spacing.rootHorizontal) < 0.01)
        #expect(abs(level2Frame.minX - servicesFrame.maxX - spacing.horizontal) < 0.01)
    }

    @Test func colorHelpers() throws {
        #expect(HexColor.tint("#F2A16D", amount: 0) == "#FFFFFF")
        #expect(HexColor.tint("#F2A16D", amount: 1) == "#F2A16D")
        // Pale orange tint and dark brown shade (XMind: #FCE9DE / #5A2E14).
        let tint = try #require(HexColor.parse(HexColor.tint("#F2A16D", amount: NodeAppearance.tintAmount)))
        #expect(tint.red > 0.97 && tint.green > 0.88 && tint.blue > 0.83)
        let shade = try #require(HexColor.parse(HexColor.darkShade("#F2A16D")))
        #expect(shade.red > shade.green && shade.green > shade.blue && shade.red < 0.45)
        for hex in ColorTheme.rainbowPalette { #expect(HexColor.prefersDarkText(on: hex)) }
    }

    @Test func renderReferenceSnapshot() throws {
        let editor = EditorController(model: MindMapModel(map: StyleSnapshotTests.sampleMap()))
        let size = CGSize(width: 1000, height: 400)
        editor.updateViewSize(size)
        let bounds = editor.scene.layout.bounds
        editor.viewport = Viewport(scale: 1, offset: CGPoint(x: (size.width / 2 - bounds.midX).rounded(),
                                                             y: (size.height / 2 - bounds.midY).rounded()))
        let view = CanvasView(editor: editor).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 2000)
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmind-style.png")
        try data.write(to: url)
        print("SNAPSHOT \(url.path)")
        #endif
    }
}
