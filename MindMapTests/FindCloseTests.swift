import Foundation
import Testing
@testable import MindMap

/// Closing Find (Esc, or any change of the map while it is open) leaves the
/// full map with no selection on a hidden topic and nothing to step to.
@MainActor
struct FindCloseTests {
    // AC-review-2
    @Test func closingFindDropsTheMatchesAndASelectionTheFullMapHides() {
        let hidden = Node(text: "Café"), plain = Node(text: "Plain")
        let branch = Node(text: "Budget", isCollapsed: true, children: [hidden])
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", children: [branch, plain]))))
        editor.openFind()
        editor.findQuery = "cafe"
        #expect(editor.findMatches.count == 1)
        #expect(editor.selectedID == hidden.id)
        #expect(editor.scene.nodes[hidden.id] != nil)  // shown by the filter

        editor.closeFind()
        #expect(editor.scene.nodes[hidden.id] == nil)  // the branch is collapsed again
        #expect(editor.selectedID == branch.id)  // not on the invisible topic
        #expect(editor.findMatches.isEmpty)  // ⌘G / ⇧⌘G are disabled (MindMapCommands)
        #expect(editor.findQuery == "cafe")
    }
}

#if os(macOS)
/// Structural edits while the filter is on act on topics the user may not
/// see: the bar closes first (real `FindBar`, in a window).
@MainActor
@Suite(.serialized)
struct FindCloseEditTests {
    private static let settle = 300

    private func makeEditor(_ harness: CanvasEventHarness, query: String) async throws -> EditorController {
        let editor = harness.editor
        editor.openFind()
        try await harness.wait(Self.settle)
        editor.findQuery = query
        try await harness.wait(Self.settle)
        #expect(editor.isFindOpen)
        return editor
    }

    // AC-review-3
    @Test func addingAChildWhileTheFilterIsOnClosesFindAndKeepsTheChildSelected() async throws {
        let match = Node(text: "Café"), plain = Node(text: "Plain")
        let map = MindMap(root: Node(text: "r", layoutStyle: .rightMap, children: [match, plain]))
        let harness = try await CanvasEventHarness(map: map)
        defer { harness.close() }
        let editor = try await makeEditor(harness, query: "cafe")
        #expect(editor.selectedID == match.id)

        editor.addChild()
        try await harness.wait(Self.settle)
        let child = try #require(editor.model.map.node(withID: match.id)?.children.first)
        #expect(!editor.isFindOpen)
        #expect(editor.findFilteredMap == nil)
        #expect(editor.scene.nodes[child.id] != nil)
        #expect(editor.scene.nodes[plain.id] != nil)  // the full map is back
        #expect(editor.selectedID == child.id)
    }

    // AC-review-3
    @Test func deletingAMatchWhileTheFilterIsOnClosesFind() async throws {
        let match = Node(text: "Café"), plain = Node(text: "Plain")
        let map = MindMap(root: Node(text: "r", layoutStyle: .rightMap, children: [match, plain]))
        let harness = try await CanvasEventHarness(map: map)
        defer { harness.close() }
        let editor = try await makeEditor(harness, query: "cafe")

        editor.deleteSelection()
        try await harness.wait(Self.settle)
        #expect(editor.model.map.node(withID: match.id) == nil)
        #expect(!editor.isFindOpen)
        #expect(editor.findFilteredMap == nil)
        #expect(editor.findMatches.isEmpty)
        #expect(editor.scene.nodes[plain.id] != nil)
    }
}
#endif
