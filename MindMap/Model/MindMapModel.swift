import CoreGraphics
import Foundation
import Observation

/// Observable, undo-aware wrapper around a `MindMap`. Views call these
/// methods passing the environment's `UndoManager`. Every action is applied
/// atomically and registered as exactly one undo step (redo is automatic).
/// Methods return false / nil when the operation is invalid (nothing changes).
@Observable
final class MindMapModel {
    private(set) var map: MindMap
    /// Files of the package's `attachments/` folder (content of notes etc.).
    let attachmentStore: AttachmentStore
    /// Identity of this open document for this process (attachment windows
    /// find their document by it, see `OpenDocumentRegistry`). Not persisted.
    let documentID = UUID()
    /// New notes / handwritten notes without content yet (not in the map,
    /// see `MindMapModel+Drafts.swift`).
    var attachmentDrafts: [UUID: AttachmentDraft] = [:]
    /// Map / note lock state (WP12, see `DocumentLock`).
    let lock = DocumentLock()
    /// Side split of the balanced-map topics as laid out on screen now
    /// (measured; set by the editor). nil = estimated sizes (WP17).
    @ObservationIgnored var sideSplitProvider: (() -> [UUID: BalancedSplit]?)?
    /// Told about an edit refused because the map is read-only (WP15; the
    /// editor shows its notice). Argument: the refused action's name.
    @ObservationIgnored var readOnlyRejectionHandler: ((String) -> Void)?
    /// Undo / redo of an expand / collapse runs its map change through this
    /// (the editor keeps the toggled topic still on screen, WP17 anchoring);
    /// arguments: the folded / unfolded topics and the change to run.
    @ObservationIgnored var replayAnchoring: ((_ toggled: [UUID], _ apply: () -> Void) -> Void)?
    /// > 0 while `bypassingReadOnly` runs (WP15).
    @ObservationIgnored var readOnlyBypassDepth = 0

    var root: Node { map.root }

    init(map: MindMap = MindMap(), attachmentStore: AttachmentStore = AttachmentStore()) {
        self.map = map
        self.attachmentStore = attachmentStore
    }

    /// Replaces the whole map without undo (document reverted to the file's
    /// contents, e.g. changed on another device). Callers clear the undo stack.
    func replaceMap(_ map: MindMap) {
        lastStep = nil
        lastContentStep = nil
        self.map = map
    }

    /// Map change whose undo is registered by the caller (content steps).
    func replaceMapKeepingUndo(_ map: MindMap) {
        self.map = map
    }

    #if DEBUG
    /// Test hook: replaces the whole map without undo (in-app event tests).
    func debugReplaceMap(_ map: MindMap) { self.map = map }
    #endif

    // MARK: Core

    /// Inverses of one registered undo step; mutable so a follow-up edit
    /// (e.g. naming a just-added topic) can join the same step.
    private final class UndoStep {
        var inverses: [MapEdit]
        init(_ inverses: [MapEdit]) { self.inverses = inverses }
    }

    /// The most recently registered step and the key it may be extended with.
    @ObservationIgnored private var lastStep: (key: UUID?, step: UndoStep, manager: ObjectIdentifier)?
    /// Last attachment content step, extended while typing continues.
    @ObservationIgnored var lastContentStep: ContentStepKey?

    /// Applies `edits` as one undo step. `coalesceKey` marks the step as
    /// extendable by `perform(_:coalescingWith:...)` with the same key.
    @discardableResult
    func perform(_ edits: [MapEdit], actionName: String, undoManager: UndoManager?,
                 coalesceKey: UUID? = nil) -> Bool {
        // Read-only maps refuse UI edits here (WP15, `MindMapModel+ReadOnly`).
        guard admits(edits, actionName: actionName, undoManager: undoManager) else { return false }
        let edits = withStableSides(edits, undoManager: undoManager)
        var newMap = map
        guard let inverses = try? newMap.apply(edits) else { return false }
        commit(newMap, edits: edits, undoManager: undoManager)
        lastContentStep = nil
        guard let undoManager else {
            lastStep = nil
            return true
        }
        let step = UndoStep(inverses)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            model.perform(step.inverses, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        let isReplay = undoManager.isUndoing || undoManager.isRedoing
        lastStep = isReplay ? nil : (coalesceKey, step, ObjectIdentifier(undoManager))
        return true
    }

    /// Applies `edits` merged into the previous undo step if that step was
    /// registered last with `key` on the same undo manager (and nothing was
    /// undone since); otherwise as a new step.
    @discardableResult
    func perform(_ edits: [MapEdit], coalescingWith key: UUID, actionName: String,
                 undoManager: UndoManager?) -> Bool {
        guard let undoManager, let last = lastStep, last.key == key,
              last.manager == ObjectIdentifier(undoManager), !undoManager.canRedo else {
            return perform(edits, actionName: actionName, undoManager: undoManager)
        }
        guard admits(edits, actionName: actionName, undoManager: undoManager) else { return false }
        let edits = withStableSides(edits, undoManager: undoManager)
        var newMap = map
        guard let inverses = try? newMap.apply(edits) else { return false }
        map = newMap
        last.step.inverses = inverses + last.step.inverses
        return true
    }

    /// Installs `newMap`. An undo / redo that only folds / unfolds topics
    /// goes through `replayAnchoring`, so ⌘Z / ⇧⌘Z of an expand keep the
    /// toggled topic where it is on screen like the action itself did.
    private func commit(_ newMap: MindMap, edits: [MapEdit], undoManager: UndoManager?) {
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing, let replayAnchoring {
            let toggled = MapEdit.collapseTargets(of: edits)
            if !toggled.isEmpty {
                var applied = false
                replayAnchoring(toggled) {
                    applied = true
                    self.map = newMap
                }
                if !applied { map = newMap }
                return
            }
        }
        map = newMap
    }

    /// `edits` plus the side edits keeping balanced-map branches where
    /// they are (WP17, part of the same undo step): sides the layout shows
    /// are stored first for topics without one (older files), then new /
    /// moved-in main topics get the lighter side and free ones the side
    /// they were dropped on. Undo / redo replay their recorded edits as is.
    private func withStableSides(_ edits: [MapEdit], undoManager: UndoManager?) -> [MapEdit] {
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return edits }
        let parents = map.balancedParents()
        guard !parents.isEmpty || edits.contains(where: MindMapModel.mayAddBalancedParent) else { return edits }
        var cachedSplit: [UUID: BalancedSplit]?
        let split = { () -> [UUID: BalancedSplit] in
            if let cachedSplit { return cachedSplit }
            let value = (self.sideSplitProvider?() ?? nil) ?? self.map.estimatedSplit()
            cachedSplit = value
            return value
        }
        let needsPins = parents.contains { $0.children.contains { $0.side == nil } }
        // Only structural edits can give a balanced parent a child without a side.
        guard needsPins || edits.contains(where: MindMapModel.mayNeedSide) else { return edits }
        let pins = needsPins ? map.sidePinEdits(split: split()) : []
        var scratch = map
        guard (try? scratch.apply(pins + edits)) != nil else { return edits }
        var explicit = Set<UUID>()
        for case let .tree(.set(id, .side(_))) in edits { explicit.insert(id) }
        // A topic created with a side (e.g. a sibling on its neighbour's side).
        for case let .tree(.insert(node, _, _)) in edits where node.side != nil { explicit.insert(node.id) }
        // Cheap check first: only compute heights when a side is missing.
        let unsettled = scratch.sideAssignmentEdits(previous: map, explicit: explicit, split: [:])
        let assigned = unsettled.isEmpty ? []
            : scratch.sideAssignmentEdits(previous: map, explicit: explicit, split: split())
        return pins + edits + assigned
    }

    /// Edits after which a child of a balanced map may need a (new) side.
    private static func mayNeedSide(_ edit: MapEdit) -> Bool {
        switch edit {
        case .tree(.insert(_, _, _)), .tree(.move(_, _, _)), .tree(.set(_, .manualPosition(_))),
             .tree(.set(_, .layoutStyle(_))), .tree(.set(_, .side(_))), .insertFloating(_, _):
            return true
        default:
            return false
        }
    }

    /// Edits that can make a topic a balanced map (layout change, a tree
    /// arriving with one): side assignment must run even without one now.
    private static func mayAddBalancedParent(_ edit: MapEdit) -> Bool {
        switch edit {
        case .tree(.set(_, .layoutStyle(_))), .tree(.insert(_, _, _)), .insertFloating(_, _): return true
        default: return false
        }
    }

    /// Ends coalescing: the next edit always registers its own undo step.
    /// Called when the document takes a save snapshot, so a rename after an
    /// autosave still registers (and marks the document dirty) instead of
    /// silently joining an already-saved "Add Topic" step.
    func breakCoalescing() {
        lastStep = nil
        lastContentStep = nil
    }

    /// Ends add+rename coalescing only (another kind of step was registered).
    func endMapCoalescing() {
        lastStep = nil
    }

    private func perform(_ actionName: String, _ undoManager: UndoManager?, _ build: () throws -> [MapEdit]) -> Bool {
        guard let edits = try? build() else { return false }
        return perform(edits, actionName: actionName, undoManager: undoManager)
    }

    // MARK: Structure

    /// Adds a new child to `parentID` (tree or floating); returns its id.
    /// The new topic's id is the coalesce key: `rename(_:to:coalescing:...)`
    /// right after joins the "Add Topic" undo step.
    @discardableResult
    func addChild(to parentID: UUID, text: String = "", undoManager: UndoManager?) -> UUID? {
        let child = Node(text: text)
        guard let edits = try? map.addChildEdits(child, to: parentID) else { return nil }
        return perform(edits, actionName: "Add Topic", undoManager: undoManager, coalesceKey: child.id) ? child.id : nil
    }

    /// Adds a new sibling after `siblingID`; returns its id. Fails for roots.
    @discardableResult
    func addSibling(after siblingID: UUID, text: String = "", undoManager: UndoManager?) -> UUID? {
        var sibling = Node(text: text)
        // Under the central topic the new topic joins its neighbour's side.
        if let parent = map.parentID(of: siblingID), map.isBalancedParent(parent),
           let reference = map.node(withID: siblingID), reference.manualPosition == nil {
            sibling.side = reference.side ?? (sideSplitProvider?() ?? nil)?[parent]?.sides[siblingID]
        }
        guard let edits = try? map.addSiblingEdits(sibling, after: siblingID) else { return nil }
        return perform(edits, actionName: "Add Topic", undoManager: undoManager, coalesceKey: sibling.id)
            ? sibling.id : nil
    }

    /// Deletes a node/floating topic with subtree, relationships and boundaries.
    @discardableResult
    func delete(_ id: UUID, undoManager: UndoManager?) -> Bool {
        perform("Delete Topic", undoManager) { try map.deleteEdits(id) }
    }

    /// Moves `id` under `newParentID` (nil index = append), also attaching a
    /// floating topic into a tree. Rejects self/descendant targets.
    /// `side`: the side of a balanced-map parent (central topic) it was
    /// dropped on (nil = the lighter side when it comes from elsewhere).
    @discardableResult
    func reparent(_ id: UUID, to newParentID: UUID, at index: Int? = nil, side: BranchSide? = nil,
                  undoManager: UndoManager?) -> Bool {
        perform("Move Topic", undoManager) {
            try map.reparentEdits(id, to: newParentID, at: index) + map.sideEdits([id], side: side, parent: newParentID)
        }
    }

    @discardableResult
    func toggleCollapse(_ id: UUID, undoManager: UndoManager?) -> Bool {
        let name = map.node(withID: id)?.isCollapsed == true ? "Expand" : "Collapse"
        return perform(name, undoManager) { try map.toggleCollapseEdits(id) }
    }

    /// With `coalescing`, the rename joins the undo step that added `id`
    /// if that was the last step (add + name = one undo step).
    @discardableResult
    func rename(_ id: UUID, to text: String, coalescing: Bool = false, undoManager: UndoManager?) -> Bool {
        guard let node = map.node(withID: id), node.text != text,
              let edits = try? map.setAttributeEdits(.text(text), for: id) else { return false }
        if coalescing {
            return perform(edits, coalescingWith: id, actionName: "Rename Topic", undoManager: undoManager)
        }
        return perform(edits, actionName: "Rename Topic", undoManager: undoManager)
    }

    // MARK: Floating topics

    /// Adds a floating topic centered at `position`; returns its id.
    @discardableResult
    func addFloating(at position: CGPoint, text: String = "", undoManager: UndoManager?) -> UUID? {
        let node = Node(text: text)
        return perform(map.addFloatingEdits(node, at: position), actionName: "Add Floating Topic",
                       undoManager: undoManager, coalesceKey: node.id) ? node.id : nil
    }

    @discardableResult
    func moveFloating(_ id: UUID, to position: CGPoint, undoManager: UndoManager?) -> Bool {
        perform("Move Topic", undoManager) { try map.moveFloatingEdits(id, to: position) }
    }

    /// Detaches a tree node (with subtree) into a floating topic.
    @discardableResult
    func detach(_ id: UUID, to position: CGPoint, undoManager: UndoManager?) -> Bool {
        perform("Detach Topic", undoManager) { try map.detachEdits(id, to: position) }
    }

    // MARK: Free position / outline (one undo step each; false = no change)

    @discardableResult
    func setManualPosition(_ id: UUID, to position: CGPoint?, undoManager: UndoManager?) -> Bool {
        guard let edits = try? map.setManualPositionEdits(id, to: position), !edits.isEmpty else { return false }
        return perform(edits, actionName: position == nil ? "Reset Position" : "Move Topic", undoManager: undoManager)
    }

    /// Clears free positions in `id`'s branch (nil = whole map).
    @discardableResult
    func resetPositions(in id: UUID? = nil, undoManager: UndoManager?) -> Bool {
        performIfAny(map.resetPositionEdits(in: id), id == nil ? "Reset All Positions" : "Reset Position", undoManager)
    }

    @discardableResult
    func collapseToLevel(_ level: Int, undoManager: UndoManager?) -> Bool {
        performIfAny(map.collapseToLevelEdits(level), "Collapse to Level \(level)", undoManager)
    }

    /// Expands `id`'s branch (nil = whole map).
    @discardableResult
    func expandAll(in id: UUID? = nil, undoManager: UndoManager?) -> Bool {
        performIfAny(map.expandAllEdits(in: id), id == nil ? "Expand All" : "Expand Branch", undoManager)
    }

    @discardableResult
    func sortChildren(_ id: UUID, ascending: Bool, undoManager: UndoManager?) -> Bool {
        performIfAny(map.sortChildrenEdits(id, ascending: ascending), "Sort Children", undoManager)
    }

    @discardableResult
    func collapseBranch(_ id: UUID, undoManager: UndoManager?) -> Bool {
        performIfAny(map.collapseBranchEdits(id), "Collapse Branch", undoManager)
    }

    private func performIfAny(_ edits: [MapEdit], _ actionName: String, _ undoManager: UndoManager?) -> Bool {
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: actionName, undoManager: undoManager)
    }

    // MARK: Styles (single node or whole branch = one undo step)

    @discardableResult
    func setAttribute(_ attribute: NodeAttribute, for id: UUID, wholeBranch: Bool = false,
                      actionName: String, undoManager: UndoManager?) -> Bool {
        perform(actionName, undoManager) { try map.setAttributeEdits(attribute, for: id, wholeBranch: wholeBranch) }
    }

    @discardableResult
    func setColor(_ id: UUID, to tag: ColorTag, undoManager: UndoManager?) -> Bool {
        setAttribute(.colorTag(tag), for: id, actionName: "Change Color", undoManager: undoManager)
    }

    /// Custom "#RRGGBB" color overriding the theme (nil clears).
    @discardableResult
    func setCustomColor(_ hex: String?, for id: UUID, wholeBranch: Bool = false, undoManager: UndoManager?) -> Bool {
        setAttribute(.customColor(hex), for: id, wholeBranch: wholeBranch, actionName: "Change Color",
                     undoManager: undoManager)
    }

    /// Sets (or clears with nil = inherit) the layout style of `id`'s subtree.
    @discardableResult
    func setLayoutStyle(_ style: LayoutStyle?, for id: UUID, undoManager: UndoManager?) -> Bool {
        guard let node = map.node(withID: id), node.layoutStyle != style else { return false }
        return setAttribute(.layoutStyle(style), for: id, actionName: "Change Layout", undoManager: undoManager)
    }

    @discardableResult
    func setShape(_ shape: NodeShape?, for id: UUID, wholeBranch: Bool = false, undoManager: UndoManager?) -> Bool {
        setAttribute(.shape(shape), for: id, wholeBranch: wholeBranch, actionName: "Change Shape",
                     undoManager: undoManager)
    }

    @discardableResult
    func setBorderStyle(_ style: BorderStyle?, for id: UUID, wholeBranch: Bool = false,
                        undoManager: UndoManager?) -> Bool {
        setAttribute(.borderStyle(style), for: id, wholeBranch: wholeBranch, actionName: "Change Border",
                     undoManager: undoManager)
    }

    /// Branch line style for lines from `id` to its children (inherited).
    @discardableResult
    func setConnectorStyle(_ style: ConnectorStyle?, for id: UUID, undoManager: UndoManager?) -> Bool {
        setAttribute(.connectorStyle(style), for: id, actionName: "Change Line", undoManager: undoManager)
    }

    @discardableResult
    func setLineWidth(_ width: Double?, for id: UUID, undoManager: UndoManager?) -> Bool {
        setAttribute(.lineWidth(width), for: id, actionName: "Change Line", undoManager: undoManager)
    }

    @discardableResult
    func setLineDash(_ dash: LineDash?, for id: UUID, undoManager: UndoManager?) -> Bool {
        setAttribute(.lineDash(dash), for: id, actionName: "Change Line", undoManager: undoManager)
    }

    @discardableResult
    func setTheme(_ theme: ColorTheme, undoManager: UndoManager?) -> Bool {
        guard theme != map.theme else { return false }
        return perform([.setTheme(theme)], actionName: "Change Theme", undoManager: undoManager)
    }

    /// Renames a library map (WP14b): one "Rename Map" step; blank = unset.
    @discardableResult
    func setMapTitle(_ title: String?, undoManager: UndoManager?) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        guard value != map.title else { return false }
        return perform([.setTitle(value)], actionName: "Rename Map", undoManager: undoManager)
    }

    // MARK: Relationships

    @discardableResult
    func addRelationship(from: UUID, to: UUID, label: String? = nil, undoManager: UndoManager?) -> UUID? {
        let relationship = Relationship(from: from, to: to, label: label)
        return perform("Add Relationship", undoManager) { try map.addRelationshipEdits(relationship) }
            ? relationship.id : nil
    }

    @discardableResult
    func removeRelationship(_ id: UUID, undoManager: UndoManager?) -> Bool {
        perform([.removeRelationship(id: id)], actionName: "Delete Relationship", undoManager: undoManager)
    }

    @discardableResult
    func relabelRelationship(_ id: UUID, to label: String?, undoManager: UndoManager?) -> Bool {
        perform("Rename Relationship", undoManager) { try map.updateRelationshipEdits(id) { $0.label = label } }
    }

    @discardableResult
    func setRelationshipStyle(_ style: RelationshipStyle, for id: UUID, undoManager: UndoManager?) -> Bool {
        perform("Change Relationship", undoManager) { try map.updateRelationshipEdits(id) { $0.style = style } }
    }

    @discardableResult
    func setRelationshipControlOffsets(_ id: UUID, from: CGVector?, to: CGVector?, undoManager: UndoManager?) -> Bool {
        perform("Adjust Relationship", undoManager) {
            try map.updateRelationshipEdits(id) {
                $0.fromControlOffset = from
                $0.toControlOffset = to
            }
        }
    }

    // MARK: Boundaries

    @discardableResult
    func addBoundary(around nodeID: UUID, siblings: [UUID] = [], label: String? = nil,
                     undoManager: UndoManager?) -> UUID? {
        let boundary = Boundary(nodeID: nodeID, siblingIDs: siblings, label: label)
        return perform("Add Boundary", undoManager) { try map.addBoundaryEdits(boundary) } ? boundary.id : nil
    }

    @discardableResult
    func removeBoundary(_ id: UUID, undoManager: UndoManager?) -> Bool {
        perform([.removeBoundary(id: id)], actionName: "Delete Boundary", undoManager: undoManager)
    }

    @discardableResult
    func updateBoundary(_ id: UUID, label: String?, colorHex: String?, undoManager: UndoManager?) -> Bool {
        perform("Edit Boundary", undoManager) {
            try map.updateBoundaryEdits(id) {
                $0.label = label
                $0.colorHex = colorHex
            }
        }
    }
}
