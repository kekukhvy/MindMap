import CoreGraphics
import Foundation

/// How a due day relates to today.
enum DueStatus: Equatable, Comparable {
    case overdue, today, tomorrow, later
}

/// Compact due-day text + status ("Today", "Tomorrow", "Fri", "Nov 14").
struct DueLabel: Equatable {
    var text: String
    var status: DueStatus

    init(text: String, status: DueStatus) {
        self.text = text
        self.status = status
    }

    init(due: Date, now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch days {
        case ..<0: status = .overdue
        case 0: status = .today
        case 1: status = .tomorrow
        default: status = .later
        }
        switch days {
        case -1: text = "Yesterday"
        case 0: text = "Today"
        case 1: text = "Tomorrow"
        case 2...6:
            text = day.formatted(DueLabel.style(calendar).weekday(.abbreviated))
        default:
            let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
            var style = DueLabel.style(calendar).month(.abbreviated).day()
            if !sameYear { style = style.year() }
            text = day.formatted(style)
        }
    }
}

extension DueLabel {
    fileprivate static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
                         timeZone: calendar.timeZone)
    }
}

/// One row of the Tasks panel (derived from the map, never stored).
struct TaskEntry: Equatable, Identifiable {
    var id: UUID
    var text: String
    /// Ancestor texts from the tree root down to the parent (empty for roots).
    var ancestors: [String]
    var task: TaskInfo
    /// Pre-order position in the map (main tree first, then floating topics).
    var mapIndex: Int

    /// Last two ancestors: "Project › Phase" (empty for tree roots).
    var breadcrumb: String { ancestors.suffix(2).joined(separator: " › ") }

    func isOverdue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = task.dueDate else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }
}

/// Tasks: edits (one undo step each) and the derived task list.
extension MindMap {
    func task(of id: UUID) -> TaskInfo? {
        node(withID: id)?.task
    }

    /// Sets / clears `id`'s task info. Empty = no change.
    func setTaskEdits(_ task: TaskInfo?, for id: UUID) throws -> [MapEdit] {
        guard let node = node(withID: id) else { throw TreeEditError.nodeNotFound }
        guard node.task != task else { return [] }
        return try setAttributeEdits(.task(task), for: id)
    }

    /// Every task in map order (main tree first, then floating topics, pre-order).
    var allTasks: [TaskEntry] {
        var result: [TaskEntry] = []
        var index = 0
        func visit(_ node: Node, ancestors: [String]) {
            if let task = node.task {
                result.append(TaskEntry(id: node.id, text: LinkCandidate.displayText(node.text),
                                        ancestors: ancestors, task: task, mapIndex: index))
            }
            index += 1
            let path = ancestors + [LinkCandidate.displayText(node.text)]
            for child in node.children { visit(child, ancestors: path) }
        }
        for tree in trees { visit(tree, ancestors: []) }
        return result
    }

    var openTaskCount: Int {
        trees.reduce(0) { count, tree in count + tree.allNodes.filter { $0.task?.isDone == false }.count }
    }

    var hasTasks: Bool {
        trees.contains { $0.allNodes.contains { $0.task != nil } }
    }

    /// Tasks panel rows: open tasks (plus `keeping`, e.g. just completed
    /// rows still fading out, sorted as if open), then completed ones when
    /// `includeCompleted` (most recently completed first).
    /// Open order: overdue first, then by due day (none last), priority
    /// (none last), then map order.
    func taskList(includeCompleted: Bool = false, keeping: Set<UUID> = [], now: Date = Date(),
                  calendar: Calendar = .current) -> [TaskEntry] {
        let all = allTasks
        let open = all.filter { !$0.task.isDone || keeping.contains($0.id) }
        let sortedOpen = open.sorted { a, b in
            TaskOrder.precedes(a, b, now: now, calendar: calendar)
        }
        guard includeCompleted else { return sortedOpen }
        let done = all.filter { $0.task.isDone && !keeping.contains($0.id) }.sorted { a, b in
            let ta = a.task.completedAt ?? .distantPast, tb = b.task.completedAt ?? .distantPast
            return ta != tb ? ta > tb : a.mapIndex < b.mapIndex
        }
        return sortedOpen + done
    }
}

/// Sort order of open tasks in the Tasks panel.
enum TaskOrder {
    static func precedes(_ a: TaskEntry, _ b: TaskEntry, now: Date, calendar: Calendar = .current) -> Bool {
        let overdueA = a.isOverdue(now: now, calendar: calendar), overdueB = b.isOverdue(now: now, calendar: calendar)
        if overdueA != overdueB { return overdueA }
        let dueA = a.task.dueDate.map { calendar.startOfDay(for: $0) }
        let dueB = b.task.dueDate.map { calendar.startOfDay(for: $0) }
        if dueA != dueB {
            switch (dueA, dueB) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            default: return false
            }
        }
        if a.task.priority != b.task.priority {
            switch (a.task.priority, b.task.priority) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            default: return false
            }
        }
        return a.mapIndex < b.mapIndex
    }
}
