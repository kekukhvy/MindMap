import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import MindMap

struct CanvasLogicTests {
    @Test func viewportZoomKeepsAnchorFixed() {
        var viewport = Viewport(scale: 1, offset: CGPoint(x: 100, y: 50))
        let anchor = CGPoint(x: 300, y: 200)
        let mapPoint = viewport.toMap(anchor)
        viewport.zoom(to: 2, around: anchor)
        #expect(viewport.scale == 2)
        let back = viewport.toScreen(mapPoint)
        #expect(abs(back.x - anchor.x) < 0.001 && abs(back.y - anchor.y) < 0.001)
        viewport.zoom(to: 100, around: anchor)
        #expect(viewport.scale == Viewport.maxScale)
    }

    @Test func viewportFitAndReveal() {
        let bounds = CGRect(x: -500, y: -100, width: 1000, height: 200)
        let fit = Viewport.fitting(bounds, in: CGSize(width: 580, height: 400), margin: 40)
        #expect(abs(fit.scale - 0.5) < 0.001)
        let screen = fit.toScreen(bounds)
        #expect(abs(screen.midX - 290) < 0.001 && abs(screen.midY - 200) < 0.001)

        var viewport = Viewport(scale: 1, offset: .zero)
        viewport.reveal(CGRect(x: 900, y: 10, width: 50, height: 20), in: CGSize(width: 400, height: 300), margin: 20)
        #expect(viewport.toScreen(CGPoint(x: 950, y: 30)).x == 380)
        #expect(viewport.offset.y == 10)
    }

    @Test func keyMapping() {
        #expect(KeyCommandMap.command(key: .tab, modifiers: [], characters: "\t") == .addChild)
        #expect(KeyCommandMap.command(key: .return, modifiers: [], characters: "\r") == .addSibling)
        #expect(KeyCommandMap.command(key: .delete, modifiers: [], characters: "\u{7f}") == .delete)
        #expect(KeyCommandMap.command(key: .space, modifiers: [], characters: " ") == .edit)
        // Arrow keys carry .numericPad (and .function, deprecated to name) on macOS.
        #expect(KeyCommandMap.command(key: .leftArrow, modifiers: [.numericPad, .capsLock], characters: "")
            == .move(.left))
        #expect(KeyCommandMap.command(key: "/", modifiers: .command, characters: "/") == .toggleCollapse)
        #expect(KeyCommandMap.command(key: "z", modifiers: .command, characters: "z") == .undo)
        #expect(KeyCommandMap.command(key: "z", modifiers: [.command, .shift], characters: "Z") == .redo)
        #expect(KeyCommandMap.command(key: "a", modifiers: [], characters: "a") == .editReplacing("a"))
        #expect(KeyCommandMap.command(key: "A", modifiers: .shift, characters: "A") == .editReplacing("A"))
        #expect(KeyCommandMap.command(key: "c", modifiers: .command, characters: "c") == nil)
        #expect(KeyCommandMap.command(key: .tab, modifiers: .shift, characters: "\t") == nil)
    }

    @Test func appearanceDefaultsByLevel() {
        let root = NodeAppearance.resolve(shape: nil, border: nil, level: 0, colorHex: "#1E1E1E")
        #expect(root.shape == .plainText && root.fill == .none && root.weight == .heavy && root.border == nil)
        let boxedRoot = NodeAppearance.resolve(shape: .roundedRect, border: nil, level: 0, colorHex: "#2F3640")
        #expect(boxedRoot.fill == .solid && boxedRoot.textColorHex == "#FFFFFF")
        let main = NodeAppearance.resolve(shape: nil, border: nil, level: 1, colorHex: "#EE7471")
        #expect(main.fill == .solid && main.weight == .medium && main.border == nil)
        let sub = NodeAppearance.resolve(shape: nil, border: nil, level: 2, colorHex: "#EE7471")
        #expect(sub.shape == .roundedRect && sub.fill == .tint && sub.border == nil)
        let deep = NodeAppearance.resolve(shape: nil, border: nil, level: 3, colorHex: "#EE7471")
        #expect(deep.shape == .plainText && deep.fill == .none && deep.border == nil)
        let underline = NodeAppearance.resolve(shape: .underline, border: nil, level: 3, colorHex: "#EE7471")
        #expect(underline.fill == .none && underline.border == .solid)
        let boxed = NodeAppearance.resolve(shape: .rectangle, border: .dashed, level: 3, colorHex: "#E8524A")
        #expect(boxed.fill == .tint && boxed.border == .dashed)
        let plain = NodeAppearance.resolve(shape: .plainText, border: nil, level: 1, colorHex: "#E8524A")
        #expect(plain.fill == .none && plain.border == nil)
    }

    @Test func hexColors() throws {
        let rgb = try #require(HexColor.parse("#FF8000"))
        #expect(rgb.red == 1 && rgb.blue == 0)
        #expect(HexColor.string(rgb) == "#FF8000")
        #expect(HexColor.parse("nope") == nil)
        #expect(HexColor.prefersDarkText(on: "#F2C94C"))
        #expect(!HexColor.prefersDarkText(on: "#2F3640"))
    }

    @Test func elbowAndTaper() {
        var geometry = ConnectorGeometry(start: .zero, end: CGPoint(x: 100, y: 50), startAxis: .horizontal,
                                         endAxis: .horizontal, style: .elbow, startWidth: 2, endWidth: 2,
                                         dash: .solid)
        #expect(geometry.elbowPoints() == [.zero, CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50),
                                           CGPoint(x: 100, y: 50)])
        geometry.startAxis = .vertical
        #expect(geometry.elbowPoints() == [.zero, CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)])
        #expect(!geometry.isTapered)
        geometry.style = .curved
        geometry.startWidth = 6
        #expect(geometry.isTapered)
        geometry.dash = .dashed
        #expect(!geometry.isTapered)
        let scaled = geometry.transformed(by: Viewport(scale: 2, offset: CGPoint(x: 10, y: 0)))
        #expect(scaled.end == CGPoint(x: 210, y: 100) && scaled.startWidth == 12)
    }

    @Test func sceneBadgesAndUnderlineAnchors() throws {
        let leaf = Node(text: "leaf", shape: .underline, children: TestTree.leaves(1))
        let collapsed = Node(text: "c", isCollapsed: true, children: TestTree.leaves(3))
        let main = Node(text: "main", children: [Node(text: "sub", shape: .underline, children: [leaf]), collapsed])
        let map = MindMap(root: Node(text: "root", layoutStyle: .rightMap, children: [main]))
        let scene = MapScene.build(map: map, measurer: NodeMeasurer(), editing: nil)
        #expect(scene.nodes[collapsed.id]?.hiddenCount == 3)
        #expect(scene.nodes[collapsed.children[0].id] == nil)
        #expect(scene.order.first == map.root.id)
        // sub (level 2, underline) -> leaf (underline override): line runs on the underlines.
        let edge = try #require(scene.connectors.first { $0.childID == leaf.id })
        let frame = try #require(scene.layout.frames[leaf.id])
        #expect(abs(edge.geometry.end.y - (frame.maxY - NodeAppearance.underlineWidth / 2)) < 0.001)
        // Root edges are thin, not tapered.
        let rootEdge = try #require(scene.connectors.first { $0.childID == main.id })
        #expect(!rootEdge.geometry.isTapered)
        // Draft text drives the size while editing.
        let editing = MapScene.build(map: map, measurer: NodeMeasurer(),
                                     editing: (main.id, String(repeating: "W", count: 30)))
        #expect((editing.layout.frames[main.id]?.width ?? 0) > (scene.layout.frames[main.id]?.width ?? 0))
    }
}
