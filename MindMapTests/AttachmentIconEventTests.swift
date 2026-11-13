#if os(macOS)
import AppKit
import Testing
@testable import MindMap

/// Real-event test (see `CanvasEventHarness`): dragging a note icon
/// sideways over its neighbour reorders the icons; the topic stays put.
@MainActor
@Suite(.serialized)
struct AttachmentIconEventTests {
    @Test func draggingAnIconSidewaysReordersIt() async throws {
        let topic = Node(text: "Two notes")
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        let harness = try await CanvasEventHarness(map: map)
        defer { harness.close() }
        let model = harness.editor.model
        let first = try #require(model.addNote(to: topic.id, text: "first", undoManager: nil))
        let second = try #require(model.addNote(to: topic.id, text: "second", undoManager: nil))
        try await harness.wait(300)

        let frame = harness.screenFrame(of: topic.id)
        let info = try #require(harness.editor.scene.nodes[topic.id])
        let scale = harness.editor.viewport.scale
        let fontSize = info.appearance.fontSize
        let icon = AttachmentIconRow.iconSize(fontSize: fontSize) * scale
        let last = CGPoint(x: frame.maxX - info.appearance.paddingH * scale - icon / 2, y: frame.midY)
        let firstCenter = CGPoint(x: last.x - AttachmentIconRow.stride(fontSize: fontSize) * scale, y: last.y)
        try await harness.drag(from: firstCenter, to: CGPoint(x: last.x + 2, y: last.y), steps: 8)
        #expect(model.map.node(withID: topic.id)?.attachments.map(\.id) == [second, first])
        #expect(harness.undo.undoActionName == "Move Attachment")
        // The topic itself did not move (no free position, same parent).
        #expect(model.map.node(withID: topic.id)?.manualPosition == nil)
        #expect(model.map.parentID(of: topic.id) == model.root.id)
    }
}
#endif
