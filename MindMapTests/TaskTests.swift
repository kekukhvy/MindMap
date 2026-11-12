import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import MindMap

/// WP8 tasks: model ops + undo, JSON compatibility, sorting, due labels,
/// Tasks panel visibility / position / persistence, node size, editor flows.
struct TaskTests {
    /// Fixed calendar (UTC) and "now" = 2026-11-12 10:00 UTC.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    static let now = Date(timeIntervalSince1970: 1_794_477_600) // 2026-11-12 10:00 UTC

    static func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    /// Central -> [Alpha, Beta (collapsed) -> [Gamma]], floating "Free".
    static func makeMap() -> (map: MindMap, alpha: UUID, beta: UUID, gamma: UUID, free: UUID) {
        let gamma = Node(text: "Gamma")
        let beta = Node(text: "Beta", isCollapsed: true, children: [gamma])
        let alpha = Node(text: "Alpha")
        let free = Node(text: "Free")
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [alpha, beta]),
                          floatingTopics: [FloatingTopic(node: free, position: CGPoint(x: 0, y: 300))])
        return (map, alpha.id, beta.id, gamma.id, free.id)
    }

    // MARK: Model ops + undo

    @Test func taskOpsAreSingleUndoSteps() throws {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        let undo = UndoTests.makeUndoManager()
        #expect(model.makeTask(t.alpha, undoManager: undo))
        #expect(undo.undoActionName == "Convert to Task")
        #expect(model.map.task(of: t.alpha) == TaskInfo())
        #expect(model.setTaskPriority(.high, for: t.alpha, undoManager: undo))
        #expect(undo.undoActionName == "Set Priority")
        #expect(model.setTaskDueDate(Self.now, for: t.alpha, calendar: Self.calendar, undoManager: undo))
        #expect(undo.undoActionName == "Set Due Date")
        #expect(model.map.task(of: t.alpha)?.dueDate == Self.day(0)) // normalised to the day
        #expect(model.toggleTaskDone(t.alpha, now: Self.now, undoManager: undo))
        #expect(undo.undoActionName == "Complete Task")
        #expect(model.map.task(of: t.alpha)?.isDone == true)
        #expect(model.map.task(of: t.alpha)?.completedAt == Self.now)
        #expect(model.toggleTaskDone(t.alpha, undoManager: undo))
        #expect(undo.undoActionName == "Reopen Task")
        #expect(model.map.task(of: t.alpha)?.completedAt == nil)
        #expect(model.removeTask(t.alpha, undoManager: undo))
        #expect(undo.undoActionName == "Convert to Topic")
        #expect(model.map.task(of: t.alpha) == nil)

        undo.undo()
        #expect(model.map.task(of: t.alpha) == TaskInfo(priority: .high, dueDate: Self.day(0)))
        undo.undo()
        #expect(model.map.task(of: t.alpha)?.isDone == true)
        for _ in 0..<4 { undo.undo() }
        #expect(model.map == t.map)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(model.map.task(of: t.alpha) == TaskInfo())
    }

    @Test func invalidOrUnchangedTaskOpsRegisterNothing() {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        let undo = UndoTests.makeUndoManager()
        #expect(!model.removeTask(t.alpha, undoManager: undo)) // not a task
        #expect(!model.toggleTaskDone(t.alpha, undoManager: undo))
        #expect(!model.setTaskDone(t.alpha, true, undoManager: undo))
        #expect(!model.setTaskPriority(nil, for: t.alpha, undoManager: undo))
        #expect(!model.setTaskDueDate(nil, for: t.alpha, undoManager: undo))
        #expect(!model.makeTask(UUID(), undoManager: undo))
        #expect(!undo.canUndo)
        #expect(model.makeTask(t.alpha, undoManager: undo))
        #expect(!model.makeTask(t.alpha, undoManager: undo)) // already a task
        #expect(!model.setTaskDone(t.alpha, false, undoManager: undo)) // already open
        #expect(!model.setTaskPriority(nil, for: t.alpha, undoManager: undo))
    }

    @Test func priorityOrDueOnPlainTopicMakesTaskInOneStep() {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        let undo = UndoTests.makeUndoManager()
        #expect(model.setTaskPriority(.low, for: t.free, undoManager: undo)) // floating topic
        #expect(model.map.task(of: t.free) == TaskInfo(priority: .low))
        undo.undo()
        #expect(model.map.task(of: t.free) == nil)
        #expect(model.setTaskDueDate(Self.day(3), for: t.gamma, undoManager: undo))
        #expect(model.map.task(of: t.gamma)?.dueDate != nil)
        undo.undo()
        #expect(model.map == t.map)
    }

    @Test func deletingTaskTopicAndUndoRestoresTask() {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        let undo = UndoTests.makeUndoManager()
        model.makeTask(t.gamma, undoManager: undo)
        #expect(model.map.openTaskCount == 1)
        model.delete(t.beta, undoManager: undo)
        #expect(model.map.openTaskCount == 0)
        undo.undo()
        #expect(model.map.openTaskCount == 1)
    }

    // MARK: JSON

    @Test func jsonRoundTripAndCompatibility() throws {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        model.setTaskPriority(.medium, for: t.alpha, undoManager: nil)
        model.setTaskDueDate(Self.day(2), for: t.alpha, undoManager: nil)
        model.makeTask(t.free, undoManager: nil)
        model.setTaskDone(t.free, true, now: Self.now, undoManager: nil)
        model.moveTaskPanel(to: CGPoint(x: 400, y: -120), undoManager: nil)
        model.setTaskPanelCollapsed(true, undoManager: nil)
        let data = try MindMapPackage.encode(model.map)
        #expect(try MindMapPackage.decode(data) == model.map)
        let json = try #require(String(data: try JSONEncoder().encode(model.map), encoding: .utf8))
        #expect(json.contains(#""priority":2"#) && json.contains(#""isDone":true"#))
        #expect(json.contains(#""taskPanel""#) && json.contains(#""isCollapsed":true"#))
        // Topics without a task and maps without a panel state write no key.
        let plain = try JSONEncoder().encode(MindMap(root: Node(text: "x")))
        let plainJSON = String(data: plain, encoding: .utf8) ?? ""
        #expect(!plainJSON.contains("task") && !plainJSON.contains("taskPanel"))
        // Old files (no task / no taskPanel) decode unchanged.
        let old = #"{"root":{"id":"\#(UUID().uuidString)","text":"Old","children":[]}}"#
        let decoded = try JSONDecoder().decode(MindMap.self, from: Data(old.utf8))
        #expect(decoded.root.task == nil && decoded.taskPanel == nil && decoded.root.text == "Old")
    }

    @Test func badTaskValuesDecodeTolerantly() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","text":"T","task":{"isDone":"yes","priority":7,"dueDate":"x"}}"#
        let node = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        #expect(node.task == TaskInfo()) // still a task, bad fields dropped
        let empty = #"{"id":"\#(id.uuidString)","task":{}}"#
        #expect(try JSONDecoder().decode(Node.self, from: Data(empty.utf8)).task == TaskInfo())
        let notObject = #"{"id":"\#(id.uuidString)","task":true,"text":"Keep"}"#
        let decoded = try JSONDecoder().decode(Node.self, from: Data(notObject.utf8))
        #expect(decoded.task == nil && decoded.text == "Keep")
        let panel = #"{"root":{"id":"\#(id.uuidString)"},"taskPanel":{"position":"bad"}}"#
        let map = try JSONDecoder().decode(MindMap.self, from: Data(panel.utf8))
        #expect(map.taskPanel == TaskPanelState())
    }

    @Test func packageRoundTripKeepsTasksAndPanelPosition() throws {
        var map = Self.makeMap().map
        map.root.children[0].task = TaskInfo(priority: .high, dueDate: Self.day(1))
        map.taskPanel = TaskPanelState(position: CGPoint(x: 512, y: -64))
        let wrapper = try MindMapPackage.fileWrapper(for: map)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).mindmap")
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try MindMapPackage.read(FileWrapper(url: url))
        #expect(read == map)
        #expect(read.taskPanel?.position == CGPoint(x: 512, y: -64))
    }

    // MARK: Sorting + labels

    @Test func taskListSortsOverdueDuePriorityThenMapOrder() {
        func task(_ text: String, _ info: TaskInfo) -> Node { Node(text: text, task: info) }
        let a = task("A plain", TaskInfo())
        let b = task("B low", TaskInfo(priority: .low))
        let c = task("C high", TaskInfo(priority: .high))
        let d = task("D due in 3", TaskInfo(dueDate: Self.day(3)))
        let e = task("E overdue", TaskInfo(priority: .low, dueDate: Self.day(-2)))
        let f = task("F due today high", TaskInfo(priority: .high, dueDate: Self.day(0)))
        let g = task("G due today low", TaskInfo(priority: .low, dueDate: Self.day(0)))
        let h = task("H done", TaskInfo(isDone: true, completedAt: Self.now))
        let i = task("I done earlier", TaskInfo(isDone: true, completedAt: Self.day(-1)))
        let floating = task("Z floating plain", TaskInfo())
        let map = MindMap(root: Node(text: "Root", children: [a, b, Node(text: "P", children: [c, d, h]), e, f, g, i]),
                          floatingTopics: [FloatingTopic(node: floating, position: .zero)])
        let open = map.taskList(now: Self.now, calendar: Self.calendar).map(\.text)
        #expect(open == ["E overdue", "F due today high", "G due today low", "D due in 3", "C high", "B low",
                         "A plain", "Z floating plain"])
        #expect(map.openTaskCount == 8)
        let all = map.taskList(includeCompleted: true, now: Self.now, calendar: Self.calendar).map(\.text)
        #expect(Array(all.suffix(2)) == ["H done", "I done earlier"])
        // A just-completed row keeps its place among the open ones.
        let keeping = map.taskList(keeping: [h.id], now: Self.now, calendar: Self.calendar)
        #expect(keeping.count == 9 && keeping.contains { $0.id == h.id })
        let entry = map.taskList(now: Self.now, calendar: Self.calendar).first { $0.id == c.id }
        #expect(entry?.breadcrumb == "Root › P")
    }

    @Test func dueLabels() {
        let cal = Self.calendar
        #expect(DueLabel(due: Self.day(0), now: Self.now, calendar: cal) == DueLabel(text: "Today", status: .today))
        #expect(DueLabel(due: Self.day(1), now: Self.now, calendar: cal) == DueLabel(text: "Tomorrow", status: .tomorrow))
        #expect(DueLabel(due: Self.day(-1), now: Self.now, calendar: cal) == DueLabel(text: "Yesterday", status: .overdue))
        #expect(DueLabel(due: Self.day(-10), now: Self.now, calendar: cal).status == .overdue)
        #expect(DueLabel(due: Self.day(2), now: Self.now, calendar: cal).text == "Sat") // 2026-11-14
        #expect(DueLabel(due: Self.day(9), now: Self.now, calendar: cal).text == "Nov 21")
        #expect(DueLabel(due: Self.day(60), now: Self.now, calendar: cal).text.contains("2027"))
        #expect(DueQuickPick.nextWeek.date(from: Self.now, calendar: cal) == Self.day(7))
        #expect(DueQuickPick.today.date(from: Self.now, calendar: cal) == Self.day(0))
    }

    // MARK: Panel rules

    @Test func panelVisibilityRules() {
        #expect(!TaskPanelLayout.isVisible(openCount: 0, lingeringCount: 0))
        #expect(TaskPanelLayout.isVisible(openCount: 1, lingeringCount: 0))
        #expect(TaskPanelLayout.isVisible(openCount: 0, lingeringCount: 1))
        var map = Self.makeMap().map
        let bounds = CGRect(x: -50, y: -100, width: 300, height: 200)
        func panel() -> TaskPanelContent? {
            TaskPanelLayout.content(map: map, contentBounds: bounds, lingering: [], showsCompleted: false,
                                    showsAll: false, now: Self.now)
        }
        #expect(panel() == nil) // no tasks
        map.root.children[0].task = TaskInfo(isDone: true)
        #expect(panel() == nil) // only completed tasks
        let done = map.root.children[0].id
        #expect(TaskPanelLayout.content(map: map, contentBounds: bounds, lingering: [done], showsCompleted: false,
                                        showsAll: false, now: Self.now)?.entries.count == 1) // fading out
        map.floatingTopics[0].node.task = TaskInfo()
        let shown = panel()
        #expect(shown?.openCount == 1 && shown?.entries.count == 1)
        // Default: right of the content bounds, top-aligned -> never over a topic.
        #expect(shown?.frame.minX == bounds.maxX + TaskPanelLayout.margin && shown?.frame.minY == bounds.minY)
        #expect(shown?.isAutoPositioned == true)
        #expect(shown?.frame.size == TaskPanelLayout.size(visibleRows: 1, hasFooter: false, isCollapsed: false))
        map.taskPanel = TaskPanelState(position: CGPoint(x: 10, y: 20), isCollapsed: true)
        #expect(panel()?.frame == CGRect(x: 10, y: 20, width: TaskPanelLayout.width, height: TaskPanelLayout.headerHeight))
    }

    @Test func panelOverflowShowsMoreFooter() {
        let tasks = (0..<14).map { Node(text: "T\($0)", task: TaskInfo()) }
        let map = MindMap(root: Node(text: "Root", children: tasks))
        let compact = TaskPanelLayout.content(map: map, contentBounds: .zero, lingering: [], showsCompleted: false,
                                              showsAll: false, now: Self.now)
        #expect(compact?.visibleEntries.count == TaskPanelLayout.maxRows)
        #expect(compact?.hiddenCount == 4 && compact?.hasFooter == true)
        let all = TaskPanelLayout.content(map: map, contentBounds: .zero, lingering: [], showsCompleted: false,
                                          showsAll: true, now: Self.now)
        #expect(all?.visibleEntries.count == 14 && all?.hiddenCount == 0 && all?.hasFooter == true)
    }

    @Test func panelPositionAndCollapseAreUndoable() {
        let model = MindMapModel(map: Self.makeMap().map)
        let undo = UndoTests.makeUndoManager()
        #expect(model.moveTaskPanel(to: CGPoint(x: 300, y: -40), undoManager: undo))
        #expect(undo.undoActionName == "Move Tasks Panel")
        #expect(!model.moveTaskPanel(to: CGPoint(x: 300, y: -40), undoManager: undo)) // unchanged
        #expect(model.setTaskPanelCollapsed(true, undoManager: undo))
        #expect(model.moveTaskPanel(to: nil, undoManager: undo))
        #expect(undo.undoActionName == "Reset Tasks Panel")
        #expect(model.map.taskPanel == TaskPanelState(position: nil, isCollapsed: true))
        undo.undo()
        undo.undo()
        #expect(model.map.taskPanel == TaskPanelState(position: CGPoint(x: 300, y: -40)))
        undo.undo()
        #expect(model.map.taskPanel == nil)
    }

    // MARK: Topic size + scene

    @Test @MainActor func nodeSizeIncludesCheckboxPriorityAndDueChip() throws {
        var map = Self.makeMap().map
        let plainScene = MapScene.build(map: map, measurer: NodeMeasurer(), editing: nil, now: Self.now)
        let alpha = map.root.children[0].id
        map.root.children[0].task = TaskInfo(priority: .high, dueDate: Self.day(-1))
        let scene = MapScene.build(map: map, measurer: NodeMeasurer(), editing: nil, now: Self.now)
        let plain = try #require(plainScene.layout.frames[alpha])
        let task = try #require(scene.layout.frames[alpha])
        let info = try #require(scene.nodes[alpha]?.task)
        #expect(info.due?.status == .overdue && info.priority == .high && info.priorityWidth > 0)
        let font = try #require(scene.nodes[alpha]?.appearance.fontSize)
        let extra = TaskBadgeMetrics.leadingWidth(info, fontSize: font) + TaskBadgeMetrics.trailingWidth(info, fontSize: font)
        #expect(approx(task.width - plain.width, extra))
        #expect(extra > TaskBadgeMetrics.checkboxSize(fontSize: font) + info.dueTextSize.width)
    }

    @Test func keyCommandReturnWithCommandTogglesTask() {
        #expect(KeyCommandMap.command(key: .return, modifiers: .command, characters: "\r") == .toggleTaskDone)
        #expect(KeyCommandMap.command(key: .return, modifiers: [], characters: "\r") == .addSibling)
    }

    // MARK: Editor flows

    @Test @MainActor func editorPanelCompletionLingersThenHides() async throws {
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.taskLingerDelay = 0.1
        editor.convertToTask(t.gamma)
        #expect(editor.taskPanel?.openCount == 1)
        editor.togglePanelTask(t.gamma)
        #expect(editor.model.map.task(of: t.gamma)?.isDone == true)
        #expect(undo.undoActionName == "Complete Task")
        // Still listed (checked) while fading out.
        #expect(editor.taskPanel?.entries.map(\.id) == [t.gamma])
        #expect(editor.taskPanel?.openCount == 0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(editor.taskPanel == nil)
        undo.undo()
        #expect(editor.taskPanel?.entries.map(\.id) == [t.gamma])
    }

    @Test @MainActor func showTaskRevealsCollapsedAncestorAndSelects() {
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        editor.undoManager = UndoTests.makeUndoManager()
        editor.updateViewSize(CGSize(width: 800, height: 600))
        editor.model.makeTask(t.gamma, undoManager: nil)
        editor.showTask(t.gamma)
        #expect(editor.selectedID == t.gamma)
        #expect(editor.model.map.node(withID: t.beta)?.isCollapsed == false)
        #expect(editor.scene.nodes[t.gamma] != nil)
    }

    @Test @MainActor func defaultPanelNeverCoversTopicsAndZoomToFitIncludesIt() throws {
        var map = StyleSnapshotTests.sampleMap()
        map.root.children[1].children[0].task = TaskInfo()
        let editor = EditorController(model: MindMapModel(map: map))
        editor.updateViewSize(CGSize(width: 900, height: 600))
        let panel = try #require(editor.taskPanel)
        for frame in editor.scene.layout.frames.values {
            #expect(!frame.intersects(panel.frame))
        }
        editor.zoomToFit()
        let screen = editor.viewport.toScreen(panel.frame)
        #expect(CGRect(origin: .zero, size: editor.viewSize).contains(screen))
    }

    @Test @MainActor func panelDragPersistsPosition() throws {
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.updateViewSize(CGSize(width: 800, height: 600))
        editor.model.makeTask(t.alpha, undoManager: nil)
        let before = try #require(editor.taskPanel?.frame)
        editor.viewport.scale = 2
        editor.updateTaskPanelDrag(CGSize(width: 40, height: -20))
        editor.endTaskPanelDrag()
        #expect(editor.taskPanelDrag == nil)
        #expect(editor.model.map.taskPanel?.position == CGPoint(x: before.minX + 20, y: before.minY - 10))
        #expect(undo.undoActionName == "Move Tasks Panel")
        #expect(editor.taskPanel?.isAutoPositioned == false)
    }
}
