import CoreGraphics
import Foundation

/// Task priority (Reminders-like marks: high "!!!", medium "!!", low "!").
/// Stored as its number (1 = highest); unknown numbers decode as no priority.
enum TaskPriority: Int, CaseIterable, Codable, Comparable {
    case high = 1, medium = 2, low = 3

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Exclamation marks shown before the title.
    var mark: String { String(repeating: "!", count: 4 - rawValue) }

    var colorHex: String {
        switch self {
        case .high: return "#E5484D"
        case .medium: return "#F08C2E"
        case .low: return "#3D8FE0"
        }
    }
}

/// A topic converted to a task (`Node.task`): checkbox before the title,
/// optional priority and due day. nil on the node = plain topic.
struct TaskInfo: Equatable, Codable {
    var isDone: Bool
    var priority: TaskPriority?
    /// Due DAY: start of that day in the user's calendar (time ignored).
    var dueDate: Date?
    /// When the task was last marked done (nil while open).
    var completedAt: Date?

    init(isDone: Bool = false, priority: TaskPriority? = nil, dueDate: Date? = nil, completedAt: Date? = nil) {
        self.isDone = isDone
        self.priority = priority
        self.dueDate = dueDate
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case isDone, priority, dueDate, completedAt
    }

    /// Tolerant: every field optional, bad values (e.g. priority 7) -> nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isDone = (try? c.decodeIfPresent(Bool.self, forKey: .isDone)) ?? false
        priority = (try? c.decodeIfPresent(TaskPriority.self, forKey: .priority)) ?? nil
        dueDate = (try? c.decodeIfPresent(Date.self, forKey: .dueDate)) ?? nil
        completedAt = (try? c.decodeIfPresent(Date.self, forKey: .completedAt)) ?? nil
    }
}

/// Map-level state of the virtual "Tasks" panel (saved in map.json; the
/// panel's content is derived from the tasks, never stored).
struct TaskPanelState: Equatable, Codable {
    /// Top-left corner in map coordinates (root center = origin). nil = auto:
    /// right of the map's content bounds, aligned with its top.
    var position: CGPoint?
    var isCollapsed: Bool

    init(position: CGPoint? = nil, isCollapsed: Bool = false) {
        self.position = position
        self.isCollapsed = isCollapsed
    }

    private enum CodingKeys: String, CodingKey {
        case position, isCollapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = (try? c.decodeIfPresent(CGPoint.self, forKey: .position)) ?? nil
        isCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
    }
}
