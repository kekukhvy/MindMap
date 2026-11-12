import SwiftUI

/// Quick due-day choices (menus, picker popover).
enum DueQuickPick: CaseIterable {
    case today, tomorrow, nextWeek

    var title: String {
        switch self {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next Week"
        }
    }

    func date(from now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let days: Int
        switch self {
        case .today: days = 0
        case .tomorrow: days = 1
        case .nextWeek: days = 7
        }
        return calendar.date(byAdding: .day, value: days, to: today) ?? today
    }
}

/// Tasks: topic ops (one undo step each) and the virtual Tasks panel.
extension EditorController {
    func task(of id: UUID) -> TaskInfo? {
        model.map.task(of: id)
    }

    // MARK: Topic ops

    func convertToTask(_ id: UUID? = nil) {
        guard let target = id ?? selectedID else { return }
        commitEditing()
        model.makeTask(target, undoManager: undoManager)
    }

    func convertToTopic(_ id: UUID? = nil) {
        guard let target = id ?? selectedID else { return }
        commitEditing()
        lingeringTaskIDs.remove(target)
        model.removeTask(target, undoManager: undoManager)
    }

    /// Checkbox on a topic / ⌘⏎: done <-> open.
    func toggleTaskDone(_ id: UUID? = nil) {
        guard let target = id ?? selectedID, task(of: target) != nil else { return }
        commitEditing()
        lingeringTaskIDs.remove(target)
        model.toggleTaskDone(target, now: now(), undoManager: undoManager)
    }

    func setTaskPriority(_ priority: TaskPriority?, for id: UUID? = nil) {
        guard let target = id ?? selectedID else { return }
        commitEditing()
        model.setTaskPriority(priority, for: target, undoManager: undoManager)
    }

    func setTaskDueDate(_ date: Date?, for id: UUID? = nil) {
        guard let target = id ?? selectedID else { return }
        commitEditing()
        model.setTaskDueDate(date, for: target, undoManager: undoManager)
    }

    func setTaskDue(_ pick: DueQuickPick, for id: UUID? = nil) {
        setTaskDueDate(pick.date(from: now()), for: id)
    }

    /// Checkbox clicked on `id` within the double-click interval: the
    /// topic's double-click (add child) is ignored, so toggling twice
    /// quickly only toggles.
    func isRecentCheckboxClick(on id: UUID) -> Bool {
        guard let last = lastCheckboxClick, last.id == id else { return false }
        return Date().timeIntervalSince(last.time) < 0.8
    }

    /// "Choose Date…": the date picker popover on the topic.
    func beginDueDatePicker(_ id: UUID? = nil) {
        guard let target = id ?? selectedID, scene.nodes[target] != nil else { return }
        commitEditing()
        select(target)
        dueDatePickerID = target
    }

    // MARK: Tasks panel

    /// The panel as drawn now (nil = hidden: no open task).
    var taskPanel: TaskPanelContent? {
        TaskPanelLayout.content(map: model.map, contentBounds: scene.layout.bounds, lingering: lingeringTaskIDs,
                                showsCompleted: taskPanelShowsCompleted, showsAll: taskPanelShowsAll, now: now())
    }

    /// Panel checkbox: completes the task (undoable); the checked row stays
    /// for `taskLingerDelay`, then fades out. A done row reopens the task.
    func togglePanelTask(_ id: UUID) {
        guard let task = task(of: id) else { return }
        commitEditing()
        if task.isDone {
            lingeringTaskIDs.remove(id)
            model.setTaskDone(id, false, now: now(), undoManager: undoManager)
            return
        }
        guard model.setTaskDone(id, true, now: now(), undoManager: undoManager) else { return }
        lingeringTaskIDs.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + taskLingerDelay) { [weak self] in
            guard let self, self.lingeringTaskIDs.contains(id) else { return }
            withAnimation(.easeOut(duration: 0.3)) { _ = self.lingeringTaskIDs.remove(id) }
        }
    }

    /// Row click: select the topic and scroll it into view (collapsed
    /// ancestors expand as one "Show Topic" undo step, like Go to).
    func showTask(_ id: UUID) {
        commitEditing()
        cancelPick()
        show(id)
    }

    func toggleTaskPanelCollapsed() {
        commitEditing()
        let collapsed = model.map.taskPanel?.isCollapsed ?? false
        withAnimation(.snappy(duration: 0.2)) {
            _ = model.setTaskPanelCollapsed(!collapsed, undoManager: undoManager)
        }
    }

    func updateTaskPanelDrag(_ translation: CGSize) {
        taskPanelDrag = translation
    }

    /// Drop after dragging the header: the panel keeps that position (one
    /// undo step "Move Tasks Panel"; saved in map.json).
    func endTaskPanelDrag() {
        guard let translation = taskPanelDrag else { return }
        taskPanelDrag = nil
        guard translation != .zero, let frame = taskPanel?.frame else { return }
        let origin = CGPoint(x: (frame.minX + translation.width / viewport.scale).rounded(),
                             y: (frame.minY + translation.height / viewport.scale).rounded())
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { _ = model.moveTaskPanel(to: origin, undoManager: undoManager) }
    }

    /// Back to the automatic position (right of the map).
    func resetTaskPanelPosition() {
        model.moveTaskPanel(to: nil, undoManager: undoManager)
    }

    /// Map content plus the Tasks panel (Zoom to Fit).
    var contentBoundsIncludingPanel: CGRect {
        let bounds = scene.layout.bounds
        guard let panel = taskPanel else { return bounds }
        return bounds.union(panel.frame)
    }
}
