#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MindMap

/// Real-event multi-selection on the macOS canvas (see `CanvasEventHarness`):
/// ⌘-click two topics then Delete, drag a selection onto a topic, ⇧-drag
/// a rubber band on empty canvas. Each on a bare canvas and in a real
/// document window.
@MainActor
@Suite(.serialized)
struct MultiSelectEventTests {
    private func harness(_ map: MindMap, _ real: Bool) async throws -> CanvasEventHarness {
        real ? try await CanvasEventHarness(realDocumentWith: map) : try await CanvasEventHarness(map: map)
    }

    private func makeMap() -> (MindMap, root: UUID, a: UUID, b: UUID, c: UUID, d: UUID) {
        let a = Node(text: "Alpha"), b = Node(text: "Beta"), c = Node(text: "Gamma"), d = Node(text: "Delta")
        let root = Node(text: "Central", layoutStyle: .rightMap, children: [a, b, c, d])
        return (MindMap(root: root), root.id, a.id, b.id, c.id, d.id)
    }

    private func click(_ harness: CanvasEventHarness, _ point: CGPoint,
                       modifiers: NSEvent.ModifierFlags = []) async throws {
        try await harness.send(.leftMouseDown, at: point, modifiers: modifiers)
        try await harness.send(.leftMouseUp, at: point, modifiers: modifiers)
        try await harness.wait(450)
    }

    @Test(arguments: [false, true]) func commandClickTwoTopicsThenDelete(real: Bool) async throws {
        let (map, root, a, b, c, d) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        try await click(harness, harness.center(of: a))
        try await click(harness, harness.center(of: c), modifiers: .command)
        #expect(editor.selectedIDs == [a, c])
        #expect(editor.selectedID == c)
        // ⇧-click adds too.
        try await click(harness, harness.center(of: d), modifiers: .shift)
        #expect(editor.selectedIDs == [a, c, d])
        try await click(harness, harness.center(of: d), modifiers: .command)
        #expect(editor.selectedIDs == [a, c])
        let before = editor.model.map
        try await harness.key("\u{7f}", keyCode: 51)
        #expect(editor.model.map.node(withID: root)?.children.map(\.id) == [b, d])
        // One undo step brings both back.
        harness.undo.undo()
        #expect(editor.model.map == before)
        #expect(!harness.undo.canUndo)
    }

    @Test(arguments: [false, true]) func dragSelectionOntoTopicReparentsAll(real: Bool) async throws {
        let (map, root, a, b, c, d) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        try await click(harness, harness.center(of: c))
        try await click(harness, harness.center(of: a), modifiers: .command)
        #expect(editor.selectedIDs == [a, c])
        var ghosts: Set<UUID> = [], target: UUID?, lines = 0
        try await harness.drag(from: harness.center(of: a), to: harness.center(of: d)) {
            ghosts = editor.drag?.ghostIDs ?? []
            target = editor.drag?.parentTargetID
            lines = editor.dragConnectors.count
        }
        #expect(ghosts == [a, c])
        #expect(target == d)
        #expect(lines == 2)
        // Both moved under Delta in their order; one undo step.
        #expect(editor.model.map.node(withID: d)?.children.map(\.id) == [a, c])
        #expect(editor.model.map.node(withID: root)?.children.map(\.id) == [b, d])
        #expect(editor.selectedIDs == [a, c])
        harness.undo.undo()
        #expect(editor.model.map.node(withID: root)?.children.map(\.id) == [a, b, c, d])
        #expect(!harness.undo.canUndo)
    }

    @Test(arguments: [false, true]) func shiftDragDrawsMarqueeInsteadOfPanning(real: Bool) async throws {
        let (map, _, a, b, c, d) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        let viewport = editor.viewport
        let frameB = harness.screenFrame(of: b), frameC = harness.screenFrame(of: c)
        // From empty space right of Beta to the middle of Gamma.
        let start = CGPoint(x: frameB.maxX + 40, y: frameB.minY - 6)
        let end = CGPoint(x: frameC.midX, y: frameC.midY)
        var band: CGRect?
        try await harness.drag(from: start, to: end, modifiers: .shift) {
            band = editor.marquee?.rect
        }
        #expect(band != nil)
        #expect(editor.marquee == nil)
        #expect(editor.selectedIDs == [b, c])
        #expect(!editor.selectedIDs.contains(a) && !editor.selectedIDs.contains(d))
        #expect(editor.viewport == viewport) // no pan
        // A plain background drag still pans.
        try await harness.drag(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 120, y: 90))
        #expect(editor.viewport.offset != viewport.offset)
    }
}
#endif
