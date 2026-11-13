#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MindMap

/// WP15 real-event checks (synthesized mouse / key events through the real
/// SwiftUI canvas, see `CanvasEventHarness`): on a read-only map dragging a
/// topic pans instead of moving it, Delete / Tab / double-click are refused
/// with the notice, the collapse toggle still folds; the toolbar has the
/// Lock Editing toggle (snapshot of the real window with its toolbar).
@MainActor
@Suite(.serialized)
struct ReadOnlyEventTests {
    private func harness(_ map: MindMap, _ real: Bool) async throws -> CanvasEventHarness {
        real ? try await CanvasEventHarness(realDocumentWith: map) : try await CanvasEventHarness(map: map)
    }

    private func makeMap() -> (MindMap, root: UUID, a: UUID, b: UUID, c: UUID) {
        let a = Node(text: "Alpha", children: [Node(text: "Kid 1"), Node(text: "Kid 2")])
        let b = Node(text: "Beta"), c = Node(text: "Gamma")
        let root = Node(text: "Central", layoutStyle: .rightMap, children: [a, b, c])
        return (MindMap(root: root, isReadOnly: true), root.id, a.id, b.id, c.id)
    }

    @Test(arguments: [false, true]) func dragOnALockedMapPansInsteadOfMoving(real: Bool) async throws {
        let (map, root, a, b, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        editor.noticeScheduler = { _, _ in }
        let before = editor.model.map
        let offset = editor.viewport.offset
        var sawDrag = false
        // Onto a sibling (reparent), then to empty space (free move).
        try await harness.drag(from: harness.center(of: a), to: harness.center(of: b)) {
            sawDrag = editor.drag != nil
        }
        #expect(!sawDrag)
        #expect(editor.model.map == before)
        #expect(editor.model.map.parentID(of: a) == root)
        #expect(editor.viewport.offset != offset) // the canvas followed the pointer
        #expect(editor.readOnlyNotice != nil)
        let start = harness.center(of: b)
        try await harness.drag(from: start, to: CGPoint(x: start.x + 120, y: start.y + 160))
        #expect(editor.model.map == before)
        #expect(editor.model.map.node(withID: b)?.manualPosition == nil)
    }

    @Test(arguments: [false, true]) func deleteTabAndDoubleClickAreRefusedWithTheNotice(real: Bool) async throws {
        let (map, root, a, b, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        editor.noticeScheduler = { _, _ in }
        let before = editor.model.map
        try await harness.click(harness.center(of: b))
        #expect(editor.selectedID == b) // selecting works
        try await harness.key("\u{7f}", keyCode: 51) // Delete
        #expect(editor.model.map.node(withID: b) != nil)
        #expect(editor.readOnlyNotice != nil)
        editor.readOnlyNotice = nil
        try await harness.key("\t", keyCode: 48) // Tab = add child
        try await harness.key("\r", keyCode: 36) // Return = add sibling
        try await harness.key(" ", keyCode: 49) // Space = rename
        try await harness.typeText("x") // typing = rename
        #expect(editor.editingID == nil)
        #expect(editor.readOnlyNotice != nil)
        try await harness.click(harness.center(of: a), count: 2) // double-click = add child
        #expect(editor.model.map == before)
        #expect(editor.model.map.node(withID: root)?.children.count == 3)
        // Unlock (the notice's button): Delete works again.
        editor.unlockFromNotice()
        try await harness.click(harness.center(of: b))
        try await harness.key("\u{7f}", keyCode: 51)
        #expect(editor.model.map.node(withID: b) == nil)
    }

    @Test(arguments: [false, true]) func collapseToggleStillFolds(real: Bool) async throws {
        let (map, _, a, _, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        editor.select(a)
        try await harness.wait(300)
        func toggle() -> CGPoint {
            let frame = harness.screenFrame(of: a)
            return CGPoint(x: frame.maxX + 12 * editor.viewport.scale, y: frame.midY)
        }
        try await harness.click(toggle())
        #expect(editor.model.map.node(withID: a)?.isCollapsed == true)
        try await harness.wait(300)
        try await harness.click(toggle())
        #expect(editor.model.map.node(withID: a)?.isCollapsed == false)
        #expect(editor.isReadOnly)
        #expect(editor.readOnlyNotice == nil)
    }

    /// The real window: the toolbar has the Lock Editing toggle (on), the
    /// edit tools are disabled; snapshot `<container>/tmp/readonly-mac.png`.
    @Test func realWindowToolbarShowsTheLockToggle() async throws {
        let (map, _, _, b, _) = makeMap()
        let harness = try await CanvasEventHarness(realDocumentWith: map)
        defer { harness.close() }
        let editor = harness.editor
        editor.noticeScheduler = { _, _ in }
        editor.zoomToFit()
        editor.select(b)
        editor.perform(.delete) // refused: the notice shows
        try await harness.wait(700)
        let items = harness.window.toolbar?.items ?? []
        let labels = items.map(\.label)
        #expect(labels.contains(ReadOnlyToggle.title), "toolbar: \(labels)")
        if let frameView = harness.window.contentView?.superview,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-mac.png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        // Unlocked: the same window, for comparison.
        editor.setReadOnly(false)
        editor.readOnlyNotice = nil
        try await harness.wait(500)
        if let frameView = harness.window.contentView?.superview,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-mac-unlocked.png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
