import CoreGraphics
import Foundation

/// Multi-selection (XMind-like): ⌘-click toggles, ⇧-click adds (a range
/// among siblings), ⌘A selects all visible topics, Esc keeps only the
/// primary topic, ⇧/⌘-drag on empty canvas (iPad: Select mode) draws a
/// rubber band. Actions on the selection are ONE undo step each.
extension EditorController {
    var isMultiSelection: Bool { selectedIDs.count > 1 }

    func isSelected(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    /// Selected visible topics in document (draw) order.
    var selection: [UUID] { scene.order.filter(selectedIDs.contains) }

    /// Topics a menu action on `id` applies to: the whole selection when
    /// `id` is part of it (nil = the selection), else just `id`.
    func targets(for id: UUID? = nil) -> [UUID] {
        guard let id else { return selection.isEmpty ? (selectedID.map { [$0] } ?? []) : selection }
        return isSelected(id) && isMultiSelection ? selection : [id]
    }

    /// Taps toggle topics (iPad Select mode, editing boundary members).
    var tapsToggleSelection: Bool { isSelectMode || boundaryMemberEditing != nil }

    // MARK: Changing the selection

    /// Replaces the selection; `primary` (default: last in document order)
    /// becomes the keyboard focus.
    func setSelection(_ ids: some Sequence<UUID>, primary: UUID? = nil) {
        commitLabelEdit()
        if editingID != nil { commitEditing() }
        let set = Set(ids)
        selectedItem = nil
        selectedIDs = set
        let focus = primary.flatMap { set.contains($0) ? $0 : nil } ?? scene.order.last { set.contains($0) }
            ?? set.first
        selectedID = focus
    }

    /// ⌘-click: adds `id` (it becomes primary) or removes it.
    func toggleSelection(_ id: UUID) {
        let result = MarqueeSelection.toggling(id, in: selectedIDs, primary: selectedID, order: scene.order)
        setSelection(result.selection, primary: result.primary)
    }

    /// ⇧-click: selects the siblings from the primary topic to `id`, or
    /// adds `id` when they are not siblings; `id` becomes primary.
    func extendSelection(to id: UUID) {
        guard let anchor = selectedID, anchor != id else {
            setSelection(selectedIDs.union([id]), primary: id)
            return
        }
        let range = MarqueeSelection.siblingRange(from: anchor, to: id, in: model.map) ?? [id]
        setSelection(selectedIDs.union(range), primary: id)
    }

    /// ⌘A: every visible topic (the primary stays, else the central topic).
    func selectAllTopics() {
        let all = scene.order
        guard !all.isEmpty else { return }
        setSelection(all, primary: selectedID ?? model.root.id)
    }

    /// Esc: only the primary topic stays selected.
    func collapseSelectionToPrimary() {
        guard let primary = selectedID else { return }
        setSelection([primary], primary: primary)
    }

    /// A click / tap on a topic with the current modifier keys.
    func clickTopic(_ id: UUID, command: Bool = false, shift: Bool = false) {
        if tapsToggleSelection || command {
            toggleSelection(id)
        } else if shift {
            extendSelection(to: id)
        } else if editingID != id {
            select(id)
        }
    }

    // MARK: Rubber band

    /// Rubber band from `start` to `current` (screen); the topics it touches
    /// are added to the selection the drag began with (live).
    func updateMarquee(from start: CGPoint, to current: CGPoint) {
        if marquee == nil {
            commitEditing()
            cancelPick()
            marquee = MarqueeDrag(start: start, current: current, base: selectedIDs, basePrimary: selectedID)
        }
        guard var band = marquee else { return }
        band.current = current
        marquee = band
        let rect = MarqueeSelection.rect(from: viewport.toMap(band.start), to: viewport.toMap(current))
        let hits = MarqueeSelection.hits(in: rect, frames: scene.layout.frames, order: scene.order)
        let selection = band.base.union(hits)
        if selection != selectedIDs || selectedItem != nil {
            setSelection(selection, primary: band.basePrimary ?? hits.first)
        }
    }

    func endMarquee() {
        marquee = nil
    }

    // MARK: Actions on the selection (one undo step each)

    func deleteSelectedTopics() {
        commitEditing()
        let targets = model.map.movableTopics(selectedIDs)
        guard !targets.isEmpty else { return }
        // Focus afterwards: the first deleted topic's parent (if it stays).
        let next = targets.first.flatMap(model.map.parentID(of:))
        guard model.delete(targets, undoManager: undoManager) else { return }
        if let next, model.map.contains(next) { select(next) } else { select(nil) }
    }

    /// Attribute on the topics `targets(for: id)` (optionally whole branches).
    func setAttribute(_ attribute: NodeAttribute, for id: UUID?, wholeBranch: Bool = false, actionName: String) {
        commitEditing()
        model.setAttribute(attribute, for: targets(for: id), wholeBranch: wholeBranch, actionName: actionName,
                           undoManager: undoManager)
    }

    /// Collapse / expand the targets (by the state of `id` / the primary).
    func toggleCollapseTargets(_ id: UUID? = nil) {
        let ids = targets(for: id)
        guard ids.count > 1 else {
            toggleCollapse(id)
            return
        }
        commitEditing()
        let reference = (id ?? selectedID).flatMap(model.map.node(withID:))
        let collapse = !(reference?.isCollapsed ?? false)
        model.setCollapsed(collapse, for: ids, undoManager: undoManager)
        validateSelection()
    }

    /// Cmd+B / Boundary: a boundary around the selected topics (not the
    /// central one); it becomes selected.
    func addBoundaryFromSelection(_ id: UUID? = nil) {
        commitEditing()
        let members = model.map.movableTopics(targets(for: id))
        guard !members.isEmpty, let boundary = model.addBoundary(members: members, undoManager: undoManager) else {
            return
        }
        selectItem(.boundary(boundary))
    }

    // MARK: Editing boundary members

    /// "Edit Members": the members become the topic selection; clicks then
    /// toggle topics; Done stores the selection as the members (one step).
    func beginEditBoundaryMembers(_ id: UUID) {
        guard let boundary = boundary(id) else { return }
        commitEditing()
        cancelPick()
        let visible = boundary.memberIDs.filter { scene.nodes[$0] != nil }
        setSelection(visible, primary: visible.first)
        boundaryMemberEditing = id
    }

    func finishEditBoundaryMembers(commit: Bool) {
        guard let id = boundaryMemberEditing else { return }
        boundaryMemberEditing = nil
        guard commit, let boundary = boundary(id) else {
            if boundary(id) != nil { selectItem(.boundary(id)) }
            return
        }
        // Members hidden in collapsed branches stay members.
        let hidden = boundary.memberIDs.filter { scene.nodes[$0] == nil }
        let members = model.map.documentOrder(Set(hidden).union(selectedIDs)).filter { $0 != model.root.id }
        model.setBoundaryMembers(id, to: members, undoManager: undoManager)
        if self.boundary(id) != nil { selectItem(.boundary(id)) } else { select(nil) }
    }

    var memberEditPrompt: String {
        let count = selectedIDs.subtracting([model.root.id]).count
        return "Click topics to add or remove them (\(count) selected)"
    }
}
