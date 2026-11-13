import CoreGraphics
import Foundation

/// Everything the canvas needs to draw the virtual Tasks panel (derived
/// from the map + view state; nil when the panel is hidden).
struct TaskPanelContent: Equatable {
    /// All rows (open tasks, lingering just-completed ones, completed if shown).
    var entries: [TaskEntry]
    /// Rows drawn (the first `TaskPanelLayout.maxRows` unless "show all").
    var visibleEntries: [TaskEntry]
    var openCount: Int
    var isCollapsed: Bool
    /// Rows not drawn ("Show N More" footer); 0 = none hidden.
    var hiddenCount: Int
    /// Footer row present ("Show N More" / "Show Less").
    var hasFooter: Bool
    /// Panel rect in map coordinates (before any live drag).
    var frame: CGRect
    /// Position comes from the map's layout bounds (never dragged / reset).
    var isAutoPositioned: Bool
}

/// Pure geometry and visibility rules of the Tasks panel (map points at
/// zoom 1; the view scales everything with the viewport).
enum TaskPanelLayout {
    static let width: CGFloat = 280
    static let headerHeight: CGFloat = 38
    static let rowHeight: CGFloat = 42
    static let footerHeight: CGFloat = 28
    static let bottomPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    /// Rows shown before "Show N More".
    static let maxRows = 10
    /// Distance from the map's content bounds for the automatic position.
    static let margin: CGFloat = 56

    /// Shown while at least one task is open (or a just-completed row is
    /// still fading out); hidden when no open task remains.
    static func isVisible(openCount: Int, lingeringCount: Int) -> Bool {
        openCount > 0 || lingeringCount > 0
    }

    /// Automatic top-left corner: right of the content bounds, top-aligned,
    /// so it never covers a topic (the panel is not part of the layout).
    static func defaultOrigin(contentBounds: CGRect) -> CGPoint {
        CGPoint(x: (contentBounds.maxX + margin).rounded(), y: contentBounds.minY.rounded())
    }

    static func size(visibleRows: Int, hasFooter: Bool, isCollapsed: Bool) -> CGSize {
        guard !isCollapsed else { return CGSize(width: width, height: headerHeight) }
        let body = CGFloat(visibleRows) * rowHeight + (hasFooter ? footerHeight : 0) + bottomPadding
        return CGSize(width: width, height: headerHeight + body)
    }

    /// Row `index` inside a panel at `frame` (same coordinate space).
    static func rowFrame(_ index: Int, in frame: CGRect, scale: CGFloat = 1) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + (headerHeight + CGFloat(index) * rowHeight) * scale,
               width: frame.width, height: rowHeight * scale)
    }

    /// Frame of a panel the user dragged somewhere (`taskPanel.position`
    /// set), without building its rows: topics keep clear of it (WP17).
    /// Same frame as `content(...)`; nil when automatic or hidden.
    static func fixedFrame(map: MindMap, lingering: Set<UUID>, showsCompleted: Bool, showsAll: Bool) -> CGRect? {
        guard let state = map.taskPanel, let origin = state.position else { return nil }
        var open = 0, kept = 0, done = 0
        func visit(_ node: Node) {
            if let task = node.task {
                if !task.isDone { open += 1 } else if lingering.contains(node.id) { kept += 1 } else { done += 1 }
            }
            node.children.forEach(visit)
        }
        visit(map.root)
        map.floatingTopics.forEach { visit($0.node) }
        guard isVisible(openCount: open, lingeringCount: kept) else { return nil }
        let rows = open + kept + (showsCompleted ? done : 0)
        let overflow = rows > maxRows
        let visible = showsAll || !overflow ? rows : maxRows
        return CGRect(origin: origin, size: size(visibleRows: visible, hasFooter: overflow, isCollapsed: state.isCollapsed))
    }

    /// Builds the panel for `map` (nil = hidden).
    static func content(map: MindMap, contentBounds: CGRect, lingering: Set<UUID>, showsCompleted: Bool,
                        showsAll: Bool, now: Date, calendar: Calendar = .current) -> TaskPanelContent? {
        let openCount = map.openTaskCount
        let keeping = lingering.filter { map.task(of: $0) != nil }
        guard isVisible(openCount: openCount, lingeringCount: keeping.count) else { return nil }
        let entries = map.taskList(includeCompleted: showsCompleted, keeping: keeping, now: now, calendar: calendar)
        let state = map.taskPanel ?? TaskPanelState()
        let overflow = entries.count > maxRows
        let visible = showsAll || !overflow ? entries : Array(entries.prefix(maxRows))
        let size = TaskPanelLayout.size(visibleRows: visible.count, hasFooter: overflow, isCollapsed: state.isCollapsed)
        let origin = state.position ?? defaultOrigin(contentBounds: contentBounds)
        return TaskPanelContent(entries: entries, visibleEntries: visible, openCount: openCount,
                                isCollapsed: state.isCollapsed, hiddenCount: entries.count - visible.count,
                                hasFooter: overflow, frame: CGRect(origin: origin, size: size),
                                isAutoPositioned: state.position == nil)
    }
}
