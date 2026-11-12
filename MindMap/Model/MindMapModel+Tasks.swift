import CoreGraphics
import Foundation

/// Undoable task operations (one undo step each; false = invalid or no
/// change). They work on any topic, floating topics included.
extension MindMapModel {
    /// "Convert to Task": an open task without priority / due day.
    @discardableResult
    func makeTask(_ id: UUID, undoManager: UndoManager?) -> Bool {
        guard map.node(withID: id)?.task == nil else { return false }
        return setTask(TaskInfo(), for: id, actionName: "Convert to Task", undoManager: undoManager)
    }

    /// "Convert to Topic": drops the checkbox, priority and due day.
    @discardableResult
    func removeTask(_ id: UUID, undoManager: UndoManager?) -> Bool {
        guard map.node(withID: id)?.task != nil else { return false }
        return setTask(nil, for: id, actionName: "Convert to Topic", undoManager: undoManager)
    }

    /// Marks a task done (stamping `completedAt`) or open again.
    @discardableResult
    func setTaskDone(_ id: UUID, _ done: Bool, now: Date = Date(), undoManager: UndoManager?) -> Bool {
        guard var task = map.node(withID: id)?.task, task.isDone != done else { return false }
        task.isDone = done
        task.completedAt = done ? now : nil
        return setTask(task, for: id, actionName: done ? "Complete Task" : "Reopen Task", undoManager: undoManager)
    }

    @discardableResult
    func toggleTaskDone(_ id: UUID, now: Date = Date(), undoManager: UndoManager?) -> Bool {
        guard let task = map.node(withID: id)?.task else { return false }
        return setTaskDone(id, !task.isDone, now: now, undoManager: undoManager)
    }

    /// Sets / clears the priority; a plain topic becomes a task (same step).
    @discardableResult
    func setTaskPriority(_ priority: TaskPriority?, for id: UUID, undoManager: UndoManager?) -> Bool {
        guard let node = map.node(withID: id), node.task != nil || priority != nil else { return false }
        var task = node.task ?? TaskInfo()
        task.priority = priority
        return setTask(task, for: id, actionName: priority == nil ? "Clear Priority" : "Set Priority",
                       undoManager: undoManager)
    }

    /// Sets (normalised to the start of that day) / clears the due day; a
    /// plain topic becomes a task (same step).
    @discardableResult
    func setTaskDueDate(_ date: Date?, for id: UUID, calendar: Calendar = .current,
                        undoManager: UndoManager?) -> Bool {
        guard let node = map.node(withID: id), node.task != nil || date != nil else { return false }
        var task = node.task ?? TaskInfo()
        task.dueDate = date.map { calendar.startOfDay(for: $0) }
        return setTask(task, for: id, actionName: date == nil ? "Clear Due Date" : "Set Due Date",
                       undoManager: undoManager)
    }

    private func setTask(_ task: TaskInfo?, for id: UUID, actionName: String, undoManager: UndoManager?) -> Bool {
        guard let edits = try? map.setTaskEdits(task, for: id), !edits.isEmpty else { return false }
        return perform(edits, actionName: actionName, undoManager: undoManager)
    }

    // MARK: Tasks panel (saved document data -> undoable, marks the document dirty)

    /// Moves the panel's top-left corner (map coordinates); nil = automatic.
    @discardableResult
    func moveTaskPanel(to position: CGPoint?, undoManager: UndoManager?) -> Bool {
        var state = map.taskPanel ?? TaskPanelState()
        guard state.position != position else { return false }
        state.position = position
        return perform([.setTaskPanel(state)], actionName: position == nil ? "Reset Tasks Panel" : "Move Tasks Panel",
                       undoManager: undoManager)
    }

    @discardableResult
    func setTaskPanelCollapsed(_ collapsed: Bool, undoManager: UndoManager?) -> Bool {
        var state = map.taskPanel ?? TaskPanelState()
        guard state.isCollapsed != collapsed else { return false }
        state.isCollapsed = collapsed
        return perform([.setTaskPanel(state)],
                       actionName: collapsed ? "Collapse Tasks Panel" : "Expand Tasks Panel",
                       undoManager: undoManager)
    }
}
