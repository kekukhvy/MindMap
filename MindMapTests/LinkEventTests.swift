#if os(macOS)
import AppKit
import Testing
@testable import MindMap

/// Real-event link tests (see `CanvasEventHarness`): plain click and
/// Cmd+click on a linked topic only select (Cmd+click toggles the
/// multi-selection, never follows the link); a click on the link icon jumps
/// to the target (expanding the collapsed parent), the Back pill returns.
@MainActor
@Suite(.serialized)
struct LinkEventTests {
    @Test(arguments: [false, true]) func commandClickTogglesSelectionAndIconFollowsLink(real: Bool) async throws {
        let target = Node(text: "Target")
        let parent = Node(text: "Folded", isCollapsed: true, children: [target])
        var source = Node(text: "Source with link")
        source.link = .topic(target.id)
        let other = Node(text: "Other")
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [source, parent, other]))
        let harness = real ? try await CanvasEventHarness(realDocumentWith: map) : try await CanvasEventHarness(map: map)
        defer { harness.close() }
        let editor = harness.editor

        // Plain click: selects only.
        try await harness.click(harness.center(of: other.id))
        #expect(editor.selectedID == other.id)

        // Cmd+click on the linked topic (on its title, not the icon): added
        // to the selection, the link is NOT followed.
        let point = CGPoint(x: harness.screenFrame(of: source.id).maxX - 12, y: harness.center(of: source.id).y)
        try await harness.send(.leftMouseDown, at: point, modifiers: .command)
        try await harness.send(.leftMouseUp, at: point, modifiers: .command)
        try await harness.wait(600)
        #expect(editor.selectedIDs == [other.id, source.id])
        #expect(editor.selectedID == source.id)
        #expect(editor.backTargetID == nil)
        #expect(editor.model.map.node(withID: parent.id)?.isCollapsed == true)

        // Cmd+click again: removed from the selection, still no navigation.
        try await harness.send(.leftMouseDown, at: point, modifiers: .command)
        try await harness.send(.leftMouseUp, at: point, modifiers: .command)
        try await harness.wait(600)
        #expect(editor.selectedIDs == [other.id])
        #expect(editor.backTargetID == nil)

        // Plain click on the link icon (before the title) = Go to.
        let info = try #require(editor.scene.nodes[source.id])
        let scale = editor.viewport.scale
        let sourceFrame = harness.screenFrame(of: source.id)
        let icon = LinkIconMetrics.iconSize(fontSize: info.appearance.fontSize) * scale
        try await harness.click(CGPoint(x: sourceFrame.minX + info.appearance.paddingH * scale + icon / 2,
                                        y: sourceFrame.midY))
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
    }
}
#endif
