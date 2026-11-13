import Foundation
import Testing
@testable import MindMap

/// Find (⌘F) fixes: the find field keeps the topic shortcuts off, the
/// filtered map is built once per query / map change, and a phrase needs
/// at least `MindMap.findMinimumLength` characters.
@MainActor
struct FindFixTests {
    /// Scene reads timed per run (the canvas reads the scene many times a frame).
    private static let sceneReads = 200
    /// The bundled sample repeated under the central topic: a large real map.
    private static let sampleCopies = 10
    /// Reads with the filter on may cost at most this many times the reads without it.
    private static let maxFilteredReadRatio = 4.0

    // AC-find-fix-1
    @Test func focusedFindFieldTurnsTheTopicShortcutsOff() {
        let topic = Node(text: "Café")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", children: [topic]))))
        editor.select(topic.id)
        #expect(editor.commandState.isEditing == false)
        #expect(editor.acceptsCanvasKeys)

        editor.openFind()
        editor.isFindFieldFocused = true
        #expect(editor.commandState.isEditing == true)  // menu Space / Return / Tab / Delete off
        #expect(!editor.acceptsCanvasKeys)

        editor.closeFind()
        #expect(!editor.isFindFieldFocused)
        #expect(editor.acceptsCanvasKeys)
    }

    // AC-find-fix-2
    @Test func filteredSceneReadsCostAboutAsMuchAsUnfilteredOnes() throws {
        let sample = try LayoutStabilityTests.featuresMap()
        let copies = (0..<Self.sampleCopies).map { _ in fresh(sample.root) }
        let map = MindMap(root: Node(text: "r", children: copies))
        let editor = EditorController(model: MindMapModel(map: map))
        editor.updateViewSize(CGSize(width: 1000, height: 700))
        let plain = timeSceneReads(editor)

        editor.openFind()
        editor.findQuery = "topic"
        #expect(!editor.findMatches.isEmpty)
        let filtered = timeSceneReads(editor)
        print("AC-find-fix-2: \(map.root.allNodes.count) topics, \(editor.findMatches.count) matches,",
              "\(Self.sceneReads) scene reads: plain \(plain * 1000) ms, filtered \(filtered * 1000) ms")
        #expect(filtered <= max(plain, 0.001) * Self.maxFilteredReadRatio)
    }

    // AC-find-fix-min3
    @Test func phraseShorterThanTheMinimumFindsAndFiltersNothing() {
        let cafe = Node(text: "Café"), plain = Node(text: "Plain")
        let model = MindMapModel(map: MindMap(root: Node(text: "r", children: [cafe, plain])))
        let editor = EditorController(model: model)
        let full = Set(editor.scene.nodes.keys)
        editor.openFind()

        editor.findQuery = "ca"
        #expect(editor.findMatches.isEmpty)
        #expect(editor.findFilteredMap == nil)
        #expect(editor.selectedID == nil)
        #expect(Set(editor.scene.nodes.keys) == full)

        editor.findQuery = "caf"
        #expect(editor.findMatches.map(\.topicID) == [cafe.id])
        #expect(editor.selectedID == cafe.id)
        #expect(!editor.scene.nodes.keys.contains(plain.id))
    }

    /// `node`'s texts and tree with new IDs (copies can sit side by side).
    private func fresh(_ node: Node) -> Node {
        Node(text: node.text, children: node.children.map(fresh))
    }

    private func timeSceneReads(_ editor: EditorController) -> TimeInterval {
        _ = editor.scene
        let start = Date()
        for _ in 0..<Self.sceneReads { _ = editor.scene }
        return Date().timeIntervalSince(start)
    }
}
