#if os(macOS)
import AppKit
import Testing
@testable import MindMap

/// Real-event task tests (see `CanvasEventHarness`), on a bare canvas and in
/// a real document window: the checkbox on a topic toggles it (no drag, the
/// topic gets selected), a click on a Tasks panel row selects + reveals the
/// topic, completing the last open task in the panel hides the panel, and
/// dragging the panel header moves it (one undo step).
@MainActor
@Suite(.serialized)
struct TaskEventTests {
    /// Central -> [Write spec (task), Folded (collapsed) -> [Hidden task (task)]].
    private func makeMap() -> (MindMap, spec: UUID, folded: UUID, hidden: UUID) {
        let hidden = Node(text: "Hidden task", task: TaskInfo())
        let folded = Node(text: "Folded", isCollapsed: true, children: [hidden])
        let spec = Node(text: "Write spec", task: TaskInfo(priority: .high))
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [spec, folded]),
                          taskPanel: TaskPanelState(position: CGPoint(x: 220, y: -260)))
        return (map, spec.id, folded.id, hidden.id)
    }

    private func harness(_ map: MindMap, _ real: Bool) async throws -> CanvasEventHarness {
        let harness = real ? try await CanvasEventHarness(realDocumentWith: map) : try await CanvasEventHarness(map: map)
        harness.editor.viewport = Viewport(scale: 1, offset: CGPoint(x: 250, y: 300))
        harness.editor.taskLingerDelay = 0.3
        try await harness.wait(300)
        return harness
    }

    private func panelScreenFrame(_ editor: EditorController) throws -> CGRect {
        editor.viewport.toScreen(try #require(editor.taskPanel).frame)
    }

    @Test(arguments: [false, true]) func clickCheckboxOnTopicToggles(real: Bool) async throws {
        let (map, spec, _, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        let info = try #require(editor.scene.nodes[spec])
        let scale = editor.viewport.scale
        let frame = harness.screenFrame(of: spec)
        let checkbox = CGPoint(x: frame.minX + info.appearance.paddingH * scale
                                   + TaskBadgeMetrics.checkboxSize(fontSize: info.appearance.fontSize) * scale / 2,
                               y: frame.midY)
        try await harness.click(checkbox)
        #expect(editor.model.map.task(of: spec)?.isDone == true)
        #expect(editor.selectedID == spec)
        #expect(editor.drag == nil && editor.model.map.node(withID: spec)?.manualPosition == nil)
        #expect(harness.undo.undoActionName == "Complete Task")
        #expect(editor.editingID == nil)
        try await harness.click(checkbox)
        #expect(editor.model.map.task(of: spec)?.isDone == false)
        // Two quick checkbox clicks are not a double-click (no child added).
        #expect(editor.model.map.node(withID: spec)?.children.isEmpty == true)
        harness.undo.undo()
        #expect(editor.model.map.task(of: spec)?.isDone == true)
        // A plain click on the title only selects.
        try await harness.click(CGPoint(x: frame.maxX - 10, y: frame.midY))
        #expect(editor.model.map.task(of: spec)?.isDone == true)
    }

    @Test(arguments: [false, true]) func clickPanelRowSelectsAndRevealsTopic(real: Bool) async throws {
        let (map, spec, folded, hidden) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        #expect(editor.scene.nodes[hidden] == nil) // inside a collapsed branch
        let panel = try #require(editor.taskPanel)
        #expect(panel.visibleEntries.map(\.id) == [spec, hidden]) // priority first
        let frame = try panelScreenFrame(editor)
        let row = TaskPanelLayout.rowFrame(1, in: frame, scale: editor.viewport.scale)
        try await harness.click(CGPoint(x: row.midX + 20, y: row.midY))
        #expect(editor.selectedID == hidden)
        #expect(editor.model.map.node(withID: folded)?.isCollapsed == false)
        #expect(editor.scene.nodes[hidden] != nil)
        #expect(editor.model.map.task(of: hidden)?.isDone == false) // row click does not complete
        let target = harness.screenFrame(of: hidden)
        #expect(CGRect(origin: .zero, size: editor.viewSize).contains(target))
    }

    @Test(arguments: [false, true]) func completingLastOpenTaskInPanelHidesPanel(real: Bool) async throws {
        let only = Node(text: "Only task", task: TaskInfo())
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [only, Node(text: "Plain")]),
                          taskPanel: TaskPanelState(position: CGPoint(x: 220, y: -200)))
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        let frame = try panelScreenFrame(editor)
        let scale = editor.viewport.scale
        let row = TaskPanelLayout.rowFrame(0, in: frame, scale: scale)
        try await harness.send(.leftMouseDown, at: CGPoint(x: row.minX + (10 + 17 / 2) * scale, y: row.midY))
        try await harness.send(.leftMouseUp, at: CGPoint(x: row.minX + (10 + 17 / 2) * scale, y: row.midY))
        try await harness.wait(100)
        #expect(editor.model.map.task(of: only.id)?.isDone == true)
        #expect(harness.undo.undoActionName == "Complete Task")
        #expect(editor.taskPanel != nil) // checked row still fading out
        try await harness.wait(800)
        #expect(editor.taskPanel == nil)
        // Undo brings the task and the panel back.
        harness.undo.undo()
        try await harness.wait(300)
        #expect(editor.taskPanel?.openCount == 1)
    }

    @Test(arguments: [false, true]) func dragPanelHeaderMovesIt(real: Bool) async throws {
        let (map, _, _, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let editor = harness.editor
        let frame = try panelScreenFrame(editor)
        let start = CGPoint(x: frame.midX, y: frame.minY + TaskPanelLayout.headerHeight / 2)
        try await harness.drag(from: start, to: CGPoint(x: start.x - 120, y: start.y + 60))
        #expect(editor.model.map.taskPanel?.position == CGPoint(x: 100, y: -200))
        #expect(harness.undo.undoActionName == "Move Tasks Panel")
        #expect(editor.selectedID == nil) // the panel is not a topic
        harness.undo.undo()
        #expect(editor.model.map.taskPanel?.position == CGPoint(x: 220, y: -260))
    }
}
#endif
