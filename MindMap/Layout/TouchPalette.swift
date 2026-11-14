import CoreGraphics
import Foundation

// Pure parts of the iPad touch UX (WP11): action palette state machine,
// tap / double-tap disambiguation, palette placement and its action list.

/// Visibility of the floating action palette (iPad). The palette is
/// *requested* by a tap / squeeze and *shown* only while nothing hides it:
/// a topic selection exists (or it is an Insert palette), no pan / zoom /
/// drag / scribble is in progress and the editor is not busy (inline
/// editing, picking a target, rubber band...). A single tap shows it after
/// the double-tap interval (and after a collapse it caused has animated),
/// so a double-tap (= add child) never flashes it and it never moves while
/// the map relayouts.
struct ActionPaletteState: Equatable {
    enum Mode: Equatable {
        /// Actions for the selected topic(s).
        case selection
        /// Insert actions at a screen point over empty canvas (Pencil squeeze).
        case insert(CGPoint)
    }

    /// Gestures that hide the palette until they end.
    enum Interaction: Hashable {
        case pan, zoom, drag, scribble
    }

    private(set) var mode: Mode?
    /// Deferred show waiting for the double-tap interval to pass.
    private(set) var pendingToken: Int?
    private(set) var interactions: Set<Interaction> = []
    private var nextToken = 0

    /// Single tap: hides the palette now and shows it for the selection
    /// once `fire(token)` arrives (after `TapSequence.maxInterval`).
    mutating func schedule() -> Int {
        nextToken += 1
        mode = nil
        pendingToken = nextToken
        return nextToken
    }

    /// The deferred show of `schedule()`; stale tokens are ignored.
    mutating func fire(_ token: Int) {
        guard pendingToken == token else { return }
        pendingToken = nil
        mode = .selection
    }

    /// Immediate show for the selection (Pencil squeeze, rubber band end).
    mutating func showForSelection() {
        pendingToken = nil
        mode = .selection
    }

    mutating func showInsert(at point: CGPoint) {
        pendingToken = nil
        mode = .insert(point)
    }

    /// Tap on empty canvas, deselect, hardware keyboard, delete...
    mutating func dismiss() {
        pendingToken = nil
        mode = nil
    }

    /// The topic selection became empty: a selection palette goes away
    /// (an Insert palette stays: it works without a selection).
    mutating func selectionCleared() {
        if mode == .selection || pendingToken != nil { dismiss() }
    }

    mutating func begin(_ interaction: Interaction) {
        interactions.insert(interaction)
    }

    mutating func end(_ interaction: Interaction) {
        interactions.remove(interaction)
    }

    var isRequested: Bool { mode != nil }

    /// What is on screen now.
    /// - Parameter hasSelection: at least one topic is selected.
    /// - Parameter isBusy: editing text, picking, rubber band, member editing.
    func visibleMode(hasSelection: Bool, isBusy: Bool) -> Mode? {
        guard let mode, interactions.isEmpty, !isBusy else { return nil }
        if case .selection = mode, !hasSelection { return nil }
        return mode
    }
}

/// Tap vs double-tap on a topic, decided per tap without delaying the
/// first one (selection is immediate): the second tap on the same topic
/// within `maxInterval` and `maxDistance` is a double-tap; a third starts over.
struct TapSequence {
    enum Kind: Equatable { case single, double }

    static let maxInterval: TimeInterval = 0.3
    static let maxDistance: CGFloat = 30

    private var last: (target: UUID, time: TimeInterval, location: CGPoint)?

    mutating func classify(target: UUID, location: CGPoint, time: TimeInterval) -> Kind {
        if let last, last.target == target, time - last.time <= Self.maxInterval, time >= last.time,
           hypot(location.x - last.location.x, location.y - last.location.y) <= Self.maxDistance {
            self.last = nil
            return .double
        }
        last = (target, time, location)
        return .single
    }

    mutating func reset() {
        last = nil
    }
}

/// What a single tap does to the tapped topic's branch (iPad, WP16: tap =
/// select + fold / unfold, double-tap = add a child inside).
///
/// The fold happens **at once** in both directions (no waiting for a
/// possible second tap). The first tap of a double-tap cannot know a second
/// one follows, so the second tap reverts the fold it made (`RecentTapFold`)
/// and adds the child in the same transition; a collapsing branch stays
/// drawn, fading, until the double-tap interval has passed
/// (`EditorController.FoldEcho`), so the revert animates it back instead of
/// making it vanish and reappear.
/// A tap never collapses the central topic (that would hide the whole map);
/// a collapsed central topic still expands.
enum TopicTapPlan: Equatable {
    /// No children (or the expanded central topic): select only.
    case select
    case expand
    case collapse

    static func plan(hasChildren: Bool, isCollapsed: Bool, isMainRoot: Bool) -> TopicTapPlan {
        guard hasChildren else { return .select }
        if isCollapsed { return .expand }
        return isMainRoot ? .select : .collapse
    }
}

/// The fold / unfold a single tap just committed (one undo step). The
/// second tap of a double-tap undoes exactly that step before adding the
/// child, so the double-tap leaves one undo step (Add Topic); it is only
/// undone while it is still the latest change (`canRevert`).
struct RecentTapFold: Equatable {
    var id: UUID
    /// The tap collapsed the branch (false: expanded it).
    var collapsed: Bool
    /// Map right after the fold.
    var mapAfter: MindMap

    var actionName: String { collapsed ? "Collapse" : "Expand" }

    /// - Parameters: the topic double-tapped, the map now and the undo
    ///   manager's state.
    func canRevert(on target: UUID, map: MindMap, canUndo: Bool, canRedo: Bool, undoActionName: String) -> Bool {
        target == id && canUndo && !canRedo && undoActionName == actionName && map == mapAfter
    }
}

/// A tap on a button inside a topic (task checkbox, link icon, attachment
/// icon) also reaches the topic's tap recognizer; within this window of the
/// button press the topic tap does nothing (no fold, no double-tap).
enum TopicAccessoryTap {
    static let window: TimeInterval = 0.5

    static func isAccessory(_ tap: (id: UUID, time: TimeInterval)?, id: UUID, time: TimeInterval) -> Bool {
        guard let tap, tap.id == id else { return false }
        return abs(time - tap.time) <= window
    }
}

/// Where the palette goes: centered above the anchor (topic / selection),
/// below when there is no room above, kept inside the visible area.
enum PalettePlacement {
    struct Result: Equatable {
        var center: CGPoint
        var isAbove: Bool
    }

    /// - Parameters:
    ///   - anchor: screen rect of the topic (or selection); a zero-size rect
    ///     for a point (Insert palette).
    ///   - size: measured palette size.
    ///   - container: canvas size.
    ///   - topInset / bottomInset: banners / home indicator to keep clear.
    ///   - belowClearance: extra gap below the anchor (collapse toggle / "+"
    ///     handle of a tree-down topic).
    ///   - obstacles: other topics (screen): below is used instead of above
    ///     when it covers less of them.
    /// - Returns: nil when the anchor is entirely off screen.
    static func place(anchor: CGRect, size: CGSize, in container: CGSize, topInset: CGFloat = 0,
                      bottomInset: CGFloat = 0, margin: CGFloat = 12, gap: CGFloat = 10,
                      belowClearance: CGFloat = 0, obstacles: [CGRect] = []) -> Result? {
        guard container.width > 0, container.height > 0 else { return nil }
        let visible = CGRect(x: margin, y: margin + topInset, width: max(container.width - 2 * margin, 1),
                             height: max(container.height - 2 * margin - topInset - bottomInset, 1))
        let screen = CGRect(origin: .zero, size: container)
        guard anchor.width == 0 && anchor.height == 0 ? screen.contains(anchor.origin) : anchor.intersects(screen)
        else { return nil }
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let x = size.width >= visible.width ? visible.midX
            : min(max(anchor.midX, visible.minX + half.width), visible.maxX - half.width)
        let aboveTop = anchor.minY - gap - size.height
        let belowTop = anchor.maxY + gap + belowClearance
        let above = aboveTop >= visible.minY
            ? Result(center: CGPoint(x: x, y: aboveTop + half.height), isAbove: true) : nil
        let below = belowTop + size.height <= visible.maxY
            ? Result(center: CGPoint(x: x, y: belowTop + half.height), isAbove: false) : nil
        if let above, let below {
            return covered(by: below, size: size, obstacles: obstacles)
                < covered(by: above, size: size, obstacles: obstacles) ? below : above
        }
        if let result = above ?? below { return result }
        // Taller than the room on either side: overlap the anchor, inside the view.
        let roomAbove = anchor.minY - visible.minY, roomBelow = visible.maxY - anchor.maxY
        let y = roomAbove >= roomBelow ? visible.minY + half.height : visible.maxY - half.height
        return Result(center: CGPoint(x: x, y: y), isAbove: roomAbove >= roomBelow)
    }

    /// Area of `obstacles` the palette would cover.
    static func covered(by result: Result, size: CGSize, obstacles: [CGRect]) -> CGFloat {
        let rect = CGRect(x: result.center.x - size.width / 2, y: result.center.y - size.height / 2,
                          width: size.width, height: size.height)
        return obstacles.reduce(0) { total, obstacle in
            let overlap = rect.intersection(obstacle)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
    }

    /// Anchor of a multi-selection: the union of the selected topics when it
    /// is compact (at most half the view high), else the primary topic.
    static func anchor(primary: CGRect, selection: [CGRect], container: CGSize) -> CGRect {
        guard selection.count > 1 else { return primary }
        let union = selection.dropFirst().reduce(selection[0]) { $0.union($1) }
        return union.height <= container.height * 0.5 && union.width <= container.width ? union : primary
    }
}

/// Buttons of the action palette.
enum PaletteAction: String, CaseIterable, Hashable {
    case addChild, addSibling, rename, delete, note, link, task, boundary, collapse, more
    /// Insert palette (Pencil squeeze over empty canvas).
    case floatingTopic, drawing, attachFile, relationship
}

struct PaletteItem: Equatable, Identifiable {
    var action: PaletteAction
    var title: String
    var systemImage: String
    var isEnabled = true
    var isDestructive = false

    var id: PaletteAction { action }
}

/// What the palette needs to know about the selection.
struct PaletteContext: Equatable {
    var count: Int
    /// The primary topic is the central topic.
    var isMainRoot = false
    /// The primary topic is a tree root (central / floating): no sibling.
    var isTreeRoot = false
    var hasChildren = false
    /// Collapse state of the primary topic (Collapse vs Expand).
    var isCollapsed = false
    var isTask = false
    var isDoneTask = false
    /// Every selected topic is a task (multi: Done instead of Task).
    var allTasks = false
    var hasNote = false
    var hasLink = false
    /// At least one selected topic can be deleted / enclosed (not central).
    var hasMovable = true
    /// Read-only map (WP15): only folding and opening what exists.
    var isReadOnly = false
}

enum ActionPaletteCatalog {
    /// Single topic: Child, Sibling, Edit, Delete, Note, Link, Task, More.
    /// Several: Task/Done, Boundary, Collapse, Delete, More (actions valid for many).
    static func items(for context: PaletteContext) -> [PaletteItem] {
        guard context.count > 0 else { return [] }
        if context.isReadOnly { return readOnlyItems(for: context) }
        if context.count > 1 {
            var items = [taskItem(isTask: context.allTasks, isDone: context.isDoneTask)]
            items.append(PaletteItem(action: .boundary, title: "Boundary", systemImage: "square.dashed",
                                     isEnabled: context.hasMovable))
            if context.hasChildren {
                items.append(collapseItem(collapsed: context.isCollapsed))
            }
            items.append(PaletteItem(action: .delete, title: "Delete", systemImage: "trash",
                                     isEnabled: context.hasMovable, isDestructive: true))
            items.append(moreItem)
            return items
        }
        var items = [
            PaletteItem(action: .addChild, title: "Child", systemImage: "arrow.turn.down.right"),
            PaletteItem(action: .addSibling, title: "Sibling", systemImage: "plus.rectangle",
                        isEnabled: !context.isTreeRoot),
            PaletteItem(action: .rename, title: "Edit", systemImage: "character.cursor.ibeam"),
        ]
        if !context.isMainRoot {
            items.append(PaletteItem(action: .delete, title: "Delete", systemImage: "trash", isDestructive: true))
        }
        items.append(PaletteItem(action: .note, title: "Note", systemImage: context.hasNote ? "note.text" : "note.text.badge.plus"))
        items.append(PaletteItem(action: .link, title: "Link", systemImage: "link"))
        items.append(taskItem(isTask: context.isTask, isDone: context.isDoneTask))
        items.append(moreItem)
        return items
    }

    /// Read-only map (WP15): Expand / Collapse, Open Note, Go to (link),
    /// More (its menu shows the edit items disabled).
    static func readOnlyItems(for context: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if context.hasChildren { items.append(collapseItem(collapsed: context.isCollapsed)) }
        if context.count == 1 {
            if context.hasNote { items.append(PaletteItem(action: .note, title: "Note", systemImage: "note.text")) }
            if context.hasLink { items.append(PaletteItem(action: .link, title: "Go to", systemImage: "arrow.right.circle")) }
        }
        items.append(moreItem)
        return items
    }

    /// Insert palette at a point (Pencil squeeze over empty canvas).
    static func insertItems(hasSelection: Bool) -> [PaletteItem] {
        var items = [PaletteItem(action: .floatingTopic, title: "Topic Here", systemImage: "rectangle.dashed")]
        guard hasSelection else { return items }
        items += [
            PaletteItem(action: .addChild, title: "Child", systemImage: "arrow.turn.down.right"),
            PaletteItem(action: .note, title: "Note", systemImage: "note.text.badge.plus"),
            PaletteItem(action: .drawing, title: "Drawing", systemImage: "pencil.and.scribble"),
            PaletteItem(action: .attachFile, title: "File", systemImage: "paperclip"),
            PaletteItem(action: .relationship, title: "Relation", systemImage: "arrow.triangle.turn.up.right.diamond"),
        ]
        return items
    }

    private static func taskItem(isTask: Bool, isDone: Bool) -> PaletteItem {
        guard isTask else { return PaletteItem(action: .task, title: "Task", systemImage: "checkmark.circle") }
        return isDone ? PaletteItem(action: .task, title: "Reopen", systemImage: "circle")
            : PaletteItem(action: .task, title: "Done", systemImage: "checkmark.circle.fill")
    }

    private static func collapseItem(collapsed: Bool) -> PaletteItem {
        PaletteItem(action: .collapse, title: collapsed ? "Expand" : "Collapse",
                    systemImage: collapsed ? "plus.circle" : "minus.circle")
    }

    private static let moreItem = PaletteItem(action: .more, title: "More", systemImage: "ellipsis")
}
