import SwiftUI

/// What a topic shows of its task: checkbox, priority mark, due chip.
/// Sizes are measured once (map points at zoom 1) so the layout reserves
/// exactly what the view draws.
struct TaskSummary: Equatable {
    var isDone: Bool
    var priority: TaskPriority?
    var due: DueLabel?
    /// Measured width of the priority mark text (0 = none).
    var priorityWidth: CGFloat = 0
    /// Measured size of the due chip text (zero = none).
    var dueTextSize: CGSize = .zero

    init(isDone: Bool, priority: TaskPriority? = nil, due: DueLabel? = nil) {
        self.isDone = isDone
        self.priority = priority
        self.due = due
    }

    init(_ task: TaskInfo, now: Date, measurer: NodeMeasurer, fontSize: CGFloat) {
        self.init(isDone: task.isDone, priority: task.priority,
                  due: task.dueDate.map { DueLabel(due: $0, now: now) })
        if let priority {
            priorityWidth = measurer.textSize(priority.mark, fontSize: TaskBadgeMetrics.priorityFontSize(fontSize),
                                              weight: .heavy, minWidth: 0).width
        }
        if let due {
            dueTextSize = measurer.textSize(due.text, fontSize: TaskBadgeMetrics.dueFontSize(fontSize),
                                            weight: .semibold, minWidth: 0)
        }
    }
}

/// Pure metrics of the task decorations inside a topic (map points at zoom 1).
enum TaskBadgeMetrics {
    static func checkboxSize(fontSize: CGFloat) -> CGFloat { max(12, (fontSize * 1.05).rounded()) }
    static func gap(fontSize: CGFloat) -> CGFloat { max(3, (fontSize * 0.3).rounded()) }
    static func priorityFontSize(_ fontSize: CGFloat) -> CGFloat { (fontSize * 0.95).rounded() }
    static func dueFontSize(_ fontSize: CGFloat) -> CGFloat { max(9, (fontSize * 0.72).rounded()) }
    static let chipPaddingH: CGFloat = 5
    static let chipPaddingV: CGFloat = 1.5

    /// Checkbox + priority mark before the title.
    static func leadingWidth(_ task: TaskSummary, fontSize: CGFloat) -> CGFloat {
        let checkbox = checkboxSize(fontSize: fontSize) + gap(fontSize: fontSize)
        let priority = task.priority == nil ? 0 : task.priorityWidth + gap(fontSize: fontSize) * 0.5
        return checkbox + priority
    }

    /// Due chip after the title.
    static func trailingWidth(_ task: TaskSummary, fontSize: CGFloat) -> CGFloat {
        guard task.due != nil else { return 0 }
        return gap(fontSize: fontSize) + chipSize(task).width
    }

    static func chipSize(_ task: TaskSummary) -> CGSize {
        CGSize(width: task.dueTextSize.width + 2 * chipPaddingH, height: task.dueTextSize.height + 2 * chipPaddingV)
    }

    static func minHeight(_ task: TaskSummary, fontSize: CGFloat) -> CGFloat {
        max(checkboxSize(fontSize: fontSize), task.due == nil ? 0 : chipSize(task).height)
    }
}

/// Colors of a due chip by status (done tasks: neutral gray).
enum DueChipStyle {
    static func colors(_ status: DueStatus, isDone: Bool, textColor: Color) -> (fill: Color, text: Color) {
        if isDone { return (Color.black.opacity(0.06), textColor.opacity(0.55)) }
        switch status {
        case .overdue: return (Color(hex: "#E5484D"), .white)
        case .today: return (Color(hex: "#F08C2E"), .white)
        case .tomorrow, .later: return (Color.black.opacity(0.07), textColor.opacity(0.85))
        }
    }
}

/// Round checkbox before a task's title. Tap / click = toggle done.
struct TaskCheckboxView: View {
    let isDone: Bool
    let size: CGFloat
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .foregroundStyle(color.opacity(isDone ? 0.6 : 0.85))
                .frame(width: size * 0.92, height: size * 0.92)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isDone ? "Mark as not done" : "Mark as done")
        .accessibilityLabel(isDone ? "Done" : "Not done")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Compact due-day chip ("Today", "Nov 14"); red when overdue.
struct DueChipView: View {
    let label: DueLabel
    let isDone: Bool
    let fontSize: CGFloat
    let scale: CGFloat
    let textColor: Color

    var body: some View {
        let colors = DueChipStyle.colors(label.status, isDone: isDone, textColor: textColor)
        Text(label.text)
            .font(.system(size: TaskBadgeMetrics.dueFontSize(fontSize) * scale, weight: .semibold))
            .foregroundStyle(colors.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, TaskBadgeMetrics.chipPaddingH * scale)
            .padding(.vertical, TaskBadgeMetrics.chipPaddingV * scale)
            .background(Capsule().fill(colors.fill))
            .accessibilityLabel(label.status == .overdue ? "Overdue, due \(label.text)" : "Due \(label.text)")
    }
}

/// "!!!" / "!!" / "!" priority mark in the priority's color.
struct PriorityMarkView: View {
    let priority: TaskPriority
    let width: CGFloat
    let fontSize: CGFloat
    let scale: CGFloat
    let dimmed: Bool

    var body: some View {
        Text(priority.mark)
            .font(.system(size: TaskBadgeMetrics.priorityFontSize(fontSize) * scale, weight: .heavy))
            .foregroundStyle(Color(hex: priority.colorHex).opacity(dimmed ? 0.45 : 1))
            .lineLimit(1)
            .fixedSize()
            .frame(width: width * scale, alignment: .leading)
            .accessibilityLabel("\(priority.title) priority")
    }
}
