import CoreGraphics
import Foundation
import Testing
@testable import MindMap

/// Tasks panel: long lists scroll inside a capped panel; a read-only map's
/// panel drag pans the canvas. Read-only badge source for the Welcome /
/// Library lists. ⌘ / ⇧ + tap with an iPad hardware keyboard.
@MainActor
struct PanelAndListTests {
    private func taskMap(count: Int) -> MindMap {
        let tasks = (0..<count).map { Node(text: "Task \($0)", task: TaskInfo()) }
        return MindMap(root: Node(text: "Root", layoutStyle: .rightMap, children: tasks))
    }

    @Test func longTaskListScrollsInsideACappedPanel() throws {
        var map = taskMap(count: 30)
        map.taskPanel = TaskPanelState(position: CGPoint(x: 400, y: 0))
        let bounds = CGRect(x: -100, y: -100, width: 200, height: 200)
        let collapsed = try #require(TaskPanelLayout.content(map: map, contentBounds: bounds, lingering: [],
                                                             showsCompleted: false, showsAll: false, now: Date()))
        #expect(!collapsed.scrollsRows && collapsed.visibleEntries.count == 10 && collapsed.hiddenCount == 20)
        let all = try #require(TaskPanelLayout.content(map: map, contentBounds: bounds, lingering: [],
                                                       showsCompleted: false, showsAll: true, now: Date()))
        #expect(all.scrollsRows && all.visibleEntries.count == 30 && all.hiddenCount == 0)
        let expected = TaskPanelLayout.headerHeight + 20 * TaskPanelLayout.rowHeight + TaskPanelLayout.footerHeight
            + TaskPanelLayout.bottomPadding
        #expect(all.frame.height == expected)
        // The obstacle frame topics avoid is the same panel (WP17).
        #expect(TaskPanelLayout.fixedFrame(map: map, lingering: [], showsCompleted: false, showsAll: true) == all.frame)
        // 15 tasks fit: no scrolling.
        let few = try #require(TaskPanelLayout.content(map: taskMap(count: 15), contentBounds: bounds, lingering: [],
                                                       showsCompleted: false, showsAll: true, now: Date()))
        #expect(!few.scrollsRows && few.frame.height == TaskPanelLayout.size(visibleRows: 15, hasFooter: true,
                                                                              isCollapsed: false).height)
    }

    @Test func scrollRectOnlyWhileTheListScrolls() {
        let editor = EditorController(model: MindMapModel(map: taskMap(count: 30)))
        editor.updateViewSize(CGSize(width: 1200, height: 900))
        #expect(editor.taskListScrollRect == nil)
        editor.taskPanelShowsAll = true
        let rect = editor.taskListScrollRect
        #expect(rect != nil)
        #expect(abs((rect?.height ?? 0) - 20 * TaskPanelLayout.rowHeight * editor.viewport.scale) < 0.01)
    }

    @Test func draggingThePanelOfALockedMapPansTheCanvas() {
        let editor = EditorController(model: MindMapModel(map: taskMap(count: 2)))
        editor.undoManager = UndoTests.makeUndoManager()
        editor.updateViewSize(CGSize(width: 1000, height: 800))
        editor.setReadOnly(true)
        let start = editor.viewport.offset
        editor.updateTaskPanelDrag(CGSize(width: 40, height: 25))
        editor.updateTaskPanelDrag(CGSize(width: 60, height: 30))
        #expect(editor.viewport.offset == CGPoint(x: start.x + 60, y: start.y + 30))
        #expect(editor.taskPanelDrag == nil)
        #expect(editor.readOnlyNotice != nil)
        editor.endTaskPanelDrag()
        #expect(editor.model.map.taskPanel?.position == nil)
    }

    @Test func readOnlyFlagOfAMapFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReadOnlyFlag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var map = MindMap(root: Node(text: "Plan"))
        let plain = folder.appendingPathComponent("Plain.mindmap")
        try MapLinkTests.writeMap(map, to: plain)
        map.isReadOnly = true
        let locked = folder.appendingPathComponent("Locked.mindmap")
        try MapLinkTests.writeMap(map, to: locked)
        #expect(!MapThumbnails.isReadOnly(plain))
        #expect(MapThumbnails.isReadOnly(locked))
        #expect(!MapThumbnails.isReadOnly(folder.appendingPathComponent("Missing.mindmap")))
    }

    @Test func commandAndShiftTapsMultiSelect() throws {
        let a = Node(text: "A"), b = Node(text: "B"), c = Node(text: "C")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "R", layoutStyle: .rightMap,
                                                                                   children: [a, b, c]))))
        editor.updateViewSize(CGSize(width: 900, height: 700))
        _ = editor.touchTapTopic(a.id, at: .zero, time: 10)
        editor.hardwareModifiers = [.command]
        #expect(editor.touchTapTopic(c.id, at: .zero, time: 11) == .toggled)
        #expect(editor.selectedIDs == [a.id, c.id])
        #expect(editor.touchTapTopic(a.id, at: .zero, time: 12) == .toggled)
        #expect(editor.selectedIDs == [c.id])
        editor.hardwareModifiers = [.shift]
        _ = editor.touchTapTopic(a.id, at: .zero, time: 13)
        #expect(editor.selectedIDs == [a.id, b.id, c.id])
        editor.hardwareModifiers = []
        _ = editor.touchTapTopic(b.id, at: .zero, time: 20)
        #expect(editor.selectedIDs == [b.id])
    }

    #if os(iOS)
    @Test func touchModifiersMapToCommandAndShift() {
        #expect(ModifierTouchBridge.modifiers([.command, .alternate]) == [.command])
        #expect(ModifierTouchBridge.modifiers([.shift]) == [.shift])
        #expect(ModifierTouchBridge.modifiers([]) == [])
    }
    #endif
}
