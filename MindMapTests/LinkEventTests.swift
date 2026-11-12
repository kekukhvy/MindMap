#if os(macOS)
import AppKit
import Testing
@testable import MindMap

/// Real-event link tests (see `CanvasEventHarness`): Cmd+click on a linked
/// topic jumps to its target (expanding the collapsed parent), plain click
/// only selects, the Back pill returns, a click on the link icon jumps.
@MainActor
@Suite(.serialized)
struct LinkEventTests {
    @Test(arguments: [false, true]) func commandClickOnTopicLinkSelectsTarget(real: Bool) async throws {
        let target = Node(text: "Target")
        let parent = Node(text: "Folded", isCollapsed: true, children: [target])
        var source = Node(text: "Source with link")
        source.link = .topic(target.id)
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [source, parent]))
        let harness = real ? try await CanvasEventHarness(realDocumentWith: map) : try await CanvasEventHarness(map: map)
        defer { harness.close() }
        let editor = harness.editor

        // Plain click: selects only.
        try await harness.click(harness.center(of: source.id))
        #expect(editor.selectedID == source.id)
        #expect(editor.backTargetID == nil)

        // Cmd+click: Go to.
        let point = CGPoint(x: harness.screenFrame(of: source.id).maxX - 12, y: harness.center(of: source.id).y)
        try await harness.send(.leftMouseDown, at: point, modifiers: .command)
        try await harness.send(.leftMouseUp, at: point, modifiers: .command)
        try await harness.wait(600)
        #expect(editor.selectedID == target.id)
        #expect(editor.model.map.node(withID: parent.id)?.isCollapsed == false)
        #expect(editor.backTargetID == source.id)
        let frame = harness.screenFrame(of: target.id)
        #expect(CGRect(origin: .zero, size: editor.viewSize).contains(frame))

        // The Back pill (bottom center) returns to the source.
        try await harness.click(CGPoint(x: editor.viewSize.width / 2, y: editor.viewSize.height - 32))
        #expect(editor.selectedID == source.id)
        #expect(editor.backTargetID == nil)

        // Plain click on the link icon (before the title) = Go to.
        let info = try #require(editor.scene.nodes[source.id])
        let scale = editor.viewport.scale
        let sourceFrame = harness.screenFrame(of: source.id)
        let icon = LinkIconMetrics.iconSize(fontSize: info.appearance.fontSize) * scale
        try await harness.click(CGPoint(x: sourceFrame.minX + info.appearance.paddingH * scale + icon / 2,
                                        y: sourceFrame.midY))
        #expect(editor.selectedID == target.id)
        #expect(editor.backTargetID == source.id)
    }
}
#endif
