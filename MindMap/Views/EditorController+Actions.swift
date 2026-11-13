import SwiftUI

/// User actions. Each document change is one undo step on `undoManager`.
extension EditorController {
    // MARK: Selection

    func select(_ id: UUID?) {
        commitLabelEdit()
        if let editingID, editingID != id { commitEditing() }
        boundaryMemberEditing = nil
        selectedIDs = id.map { [$0] } ?? []
        selectedID = id
        selectedItem = nil
    }

    /// Selects a relationship / boundary (deselects topics).
    func selectItem(_ item: CanvasItem?) {
        commitEditing()
        boundaryMemberEditing = nil
        selectedID = nil
        selectedItem = item
    }

    func move(_ direction: MoveDirection) {
        guard let current = selectedID, scene.nodes[current] != nil else {
            select(model.root.id)
            return
        }
        guard let target = scene.navigator.target(from: current, direction: direction) else { return }
        select(target)
        reveal(target)
    }

    func reveal(_ id: UUID) {
        guard let frame = scene.layout.frames[id], viewSize != .zero else { return }
        viewport.reveal(frame, in: viewSize)
    }

    // MARK: Structure

    private func defaultText(forLevel level: Int) -> String {
        level <= 1 ? "Main Topic" : "Subtopic"
    }

    /// Adds a child to the selection (or root) and starts editing it.
    func addChild() {
        commitEditing()
        let parent = selectedID ?? model.root.id
        let level = (scene.nodes[parent]?.level ?? 0) + 1
        guard let id = model.addChild(to: parent, text: defaultText(forLevel: level), undoManager: undoManager) else {
            return
        }
        startEditingNew(id)
    }

    /// Adds a sibling after the selection (a child for roots) and edits it.
    func addSibling() {
        commitEditing()
        guard let current = selectedID, let info = scene.nodes[current], !info.isTreeRoot else {
            addChild()
            return
        }
        guard let id = model.addSibling(after: current, text: defaultText(forLevel: info.level),
                                        undoManager: undoManager) else { return }
        startEditingNew(id)
    }

    func startEditingNew(_ id: UUID) {
        select(id)
        reveal(id)
        beginEditing(id)
        namingNewID = id
    }

    func deleteSelection() {
        commitEditing()
        if let item = selectedItem {
            removeItem(item)
            return
        }
        if isMultiSelection {
            deleteSelectedTopics()
            return
        }
        guard let id = selectedID, id != model.root.id else { return }
        let next = model.map.isFloatingRoot(id) ? nil : model.map.tree(containing: id)?.selectionAfterDeleting(id)
        if model.delete(id, undoManager: undoManager) { selectedID = next }
    }

    func toggleCollapse(_ id: UUID? = nil) {
        guard let id = id ?? selectedID, scene.nodes[id]?.hasChildren == true else { return }
        commitEditing()
        keepingOnScreen(id) { _ = model.toggleCollapse(id, undoManager: undoManager) }
    }

    // MARK: Inline editing

    /// Starts editing `id` (default: selection). `replacement` replaces the
    /// text (typing on a selected node); otherwise all text is selected.
    func beginEditing(_ id: UUID? = nil, replacement: String? = nil) {
        // Read-only map (WP15): no edit starts.
        guard requireEditable() else { return }
        guard let id = id ?? selectedID, let node = model.map.node(withID: id) else { return }
        if let editingID, editingID != id { commitEditing() }
        selectedIDs = [id]
        selectedID = id
        selectedItem = nil
        namingNewID = nil
        setEditing(id, text: replacement ?? node.text, selectAll: replacement == nil)
    }

    /// Commits the draft (one undo step if changed; naming a just-added
    /// topic joins its "Add Topic" step). With `id`, only if that node is
    /// still the one being edited.
    func commitEditing(ifEditing id: UUID? = nil) {
        if id == nil { commitLabelEdit() }
        guard let editingID, id == nil || id == editingID else { return }
        let text = draftText
        let coalesce = namingNewID == editingID
        namingNewID = nil
        setEditing(nil, text: "", selectAll: true)
        model.rename(editingID, to: text, coalescing: coalesce, undoManager: undoManager)
        // The committed text may have grown the topic past the view edge.
        if selectedID == editingID { reveal(editingID) }
    }

    // MARK: Drag to reparent / reorder / move floating

    /// Live drag of `id`: drop target + placement under the pointer
    /// (`freeMove` = no target, the drop moves the topic freely).
    func updateDrag(_ id: UUID, translation: CGSize, location: CGPoint, freeMove: Bool = false) {
        // Read-only map (WP15): topics stay put (the canvas pans instead).
        guard canEdit else {
            if drag == nil { showReadOnlyNotice() }
            return
        }
        if editingID != nil { commitEditing() }
        cancelPick()
        let point = viewport.toMap(location)
        // Dragging a topic of a multi-selection drags the whole selection.
        let group = isSelected(id) && isMultiSelection
        let moving = group ? model.map.movableTopics(selectedIDs.union([id])) : [id]
        let excluded = Set(moving.flatMap { model.map.node(withID: $0)?.allIDs ?? [$0] } + [id])
        let target = freeMove ? nil
            : DropTargetFinder.target(at: point, frames: scene.layout.frames, excluding: excluded)
        var drag = NodeDrag(id: id, translation: translation, targetID: target)
        drag.movingIDs = moving
        drag.ghostIDs = group ? selectedIDs.subtracting([model.root.id]).union([id]) : [id]
        drag.freeMove = freeMove
        if let target, let frame = scene.layout.frames[target], scene.nodes[target]?.isTreeRoot == false {
            drag.siblingAxis = scene.siblingAxis(of: target)
            drag.placement = DropTargetFinder.placement(at: point, in: frame, siblingAxis: drag.siblingAxis)
        }
        self.drag = drag
        if !group {
            if selectedID != id || selectedIDs.count != 1 { select(id) }
        } else if selectedID != id {
            selectedID = id
        }
        selectedItem = nil
    }

    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        if drag.movingIDs.count > 1 {
            endGroupDrag(drag)
            return
        }
        if let target = drag.targetID {
            switch drag.placement {
            case .child:
                if model.map.parentID(of: drag.id) != target {
                    model.reparent(drag.id, to: target, side: dropSide(drag, onto: target), undoManager: undoManager)
                }
            case .before, .after:
                dropAsSibling(drag.id, of: target, placement: drag.placement)
            }
        } else if model.map.isFloatingRoot(drag.id), let topic = model.map.floatingTopic(drag.id) {
            let position = CGPoint(x: topic.position.x + drag.translation.width / viewport.scale,
                                   y: topic.position.y + drag.translation.height / viewport.scale)
            model.moveFloating(drag.id, to: position, undoManager: undoManager)
        } else if drag.translation != .zero, let position = freePosition(for: drag) {
            // Empty space: the topic stays where it was dropped (free position).
            model.setManualPosition(drag.id, to: position, undoManager: undoManager)
        }
    }

    /// Drop of a multi-selection (one undo step): on a topic = all become
    /// its children, on a sibling's edge = all inserted there, on empty
    /// space = all move freely by the same offset (relative order kept).
    private func endGroupDrag(_ drag: NodeDrag) {
        let ids = drag.movingIDs
        if let target = drag.targetID {
            switch drag.placement {
            case .child: model.reparent(ids, to: target, side: dropSide(drag, onto: target), undoManager: undoManager)
            case .before, .after:
                model.insert(ids, beside: target, after: drag.placement == .after, undoManager: undoManager)
            }
        } else if drag.translation != .zero {
            let moves = ids.compactMap { id -> (id: UUID, position: CGPoint)? in
                if let topic = model.map.floatingTopic(id) {
                    return (id, CGPoint(x: topic.position.x + drag.translation.width / viewport.scale,
                                        y: topic.position.y + drag.translation.height / viewport.scale))
                }
                return freePosition(of: id, translation: drag.translation).map { (id, $0) }
            }
            model.moveTopics(moves, undoManager: undoManager)
        }
    }

    /// Side of `target` the dragged topic was dropped on (map points; for
    /// a balanced-map target such as the central topic).
    func dropSide(_ drag: NodeDrag, onto target: UUID) -> BranchSide? {
        guard let frame = scene.layout.frames[drag.id], let parent = scene.layout.frames[target] else { return nil }
        let x = frame.midX + drag.translation.width / viewport.scale
        return x < parent.midX ? .left : .right
    }

    /// Offset of the dropped topic's center from its parent's center (map points).
    func freePosition(for drag: NodeDrag) -> CGPoint? {
        freePosition(of: drag.id, translation: drag.translation)
    }

    func freePosition(of id: UUID, translation: CGSize) -> CGPoint? {
        let drag = (id: id, translation: translation)
        guard let parent = model.map.parentID(of: drag.id),
              let frame = scene.layout.frames[drag.id], let parentFrame = scene.layout.frames[parent] else { return nil }
        let x = frame.midX + drag.translation.width / viewport.scale - parentFrame.midX
        let y = frame.midY + drag.translation.height / viewport.scale - parentFrame.midY
        return CGPoint(x: (x * 2).rounded() / 2, y: (y * 2).rounded() / 2)
    }

    private func dropAsSibling(_ id: UUID, of target: UUID, placement: DropPlacement) {
        guard let parent = model.map.parentID(of: target),
              let siblings = model.map.node(withID: parent)?.children.map(\.id),
              let targetIndex = siblings.firstIndex(of: target) else { return }
        let movingIndex = model.map.parentID(of: id) == parent ? siblings.firstIndex(of: id) : nil
        let index = DropTargetFinder.insertionIndex(targetIndex: targetIndex, placement: placement,
                                                    movingIndex: movingIndex)
        // Beside a main topic = on its side of the central topic.
        let side = model.map.isBalancedParent(parent) ? model.sideOf(target) : nil
        guard index != movingIndex || (side != nil && model.map.node(withID: id)?.side != side) else { return }
        model.reparent(id, to: parent, at: index, side: side, undoManager: undoManager)
    }

    // MARK: Format

    /// Sets the layout of a topic's children (nil = inherit); the scene is
    /// rebuilt from the new map at once and the topic stays in view.
    func setLayoutStyle(_ style: LayoutStyle?, for id: UUID? = nil) {
        guard let id = id ?? selectedID else { return }
        commitEditing()
        let ids = targets(for: id)
        if ids.count > 1 {
            model.setAttribute(.layoutStyle(style), for: ids, actionName: "Change Layout", undoManager: undoManager)
            return
        }
        guard model.setLayoutStyle(style, for: id, undoManager: undoManager) else { return }
        reveal(id)
    }

    /// Clears color tag and custom color (one undo step).
    /// Clears color tag and custom color of `id` (or the whole selection
    /// it belongs to), one undo step.
    func resetColor(_ id: UUID, wholeBranch: Bool) {
        model.setAttributes([.colorTag(.none), .customColor(nil)], for: targets(for: id), wholeBranch: wholeBranch,
                            actionName: "Reset Color", undoManager: undoManager)
    }

    func applyColorSheet(_ request: ColorSheetRequest, hex: String) {
        switch request.target {
        case let .nodes(ids, wholeBranch):
            model.setAttribute(.customColor(hex), for: ids, wholeBranch: wholeBranch, actionName: "Change Color",
                               undoManager: undoManager)
        case let .relationship(id):
            setRelationshipColor(hex, for: id)
        case let .boundary(id):
            setBoundaryColor(hex, for: id)
        case .theme:
            model.setTheme(.mono(hex: hex), undoManager: undoManager)
        }
    }

    // MARK: Viewport

    func zoomToFit() {
        viewport = .fitting(contentBoundsIncludingPanel, in: viewSize)
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        viewport.zoom(to: viewport.scale * factor,
                      around: anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    // MARK: Undo

    func undo() {
        commitEditing()
        cancelPick()
        if undoManager?.canUndo == true { undoManager?.undo() }
        validateSelection()
        refreshUndoState()
    }

    func redo() {
        commitEditing()
        cancelPick()
        if undoManager?.canRedo == true { undoManager?.redo() }
        validateSelection()
        refreshUndoState()
    }

    // MARK: Keyboard

    /// Runs a keyboard command; returns false if it does not apply.
    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        guard editingID == nil, labelEditing == nil else { return false }
        // Read-only map (WP15): edit keys are swallowed with the notice.
        if command.isEdit, !requireEditable() { return true }
        switch command {
        case .addChild: addChild()
        case .addSibling: addSibling()
        case .delete: deleteSelection()
        case .edit where selectedItem != nil:
            beginLabelEdit(selectedItem!)
        case .edit, .editReplacing:
            guard selectedID != nil else { return false }
            if case let .editReplacing(text) = command { beginEditing(replacement: text) } else { beginEditing() }
        case .toggleCollapse: toggleCollapseTargets()
        case .undo: undo()
        case .redo: redo()
        case let .move(direction): move(direction)
        case .zoomIn: zoom(by: 1.25)
        case .zoomOut: zoom(by: 0.8)
        case .zoomToFit: zoomToFit()
        case .addRelationship:
            guard let id = selectedID else { return false }
            beginRelationship(from: id)
        case .addBoundary:
            guard selectedID != nil else { return false }
            addBoundaryFromSelection()
        case .selectAll:
            selectAllTopics()
        case .toggleReadOnly:
            toggleReadOnly()
        case .note:
            // One topic only (the Link / Note / Attachments submenus are
            // disabled for a multi-selection).
            guard let id = selectedID, scene.nodes[id] != nil, !isMultiSelection else { return false }
            openOrAddNote(id)
        case .handwrittenNote:
            // One topic only (the Link / Note / Attachments submenus are
            // disabled for a multi-selection).
            guard let id = selectedID, scene.nodes[id] != nil, !isMultiSelection else { return false }
            openOrAddDrawing(id)
        case .attachFile:
            // One topic only (the Link / Note / Attachments submenus are
            // disabled for a multi-selection).
            guard let id = selectedID, scene.nodes[id] != nil, !isMultiSelection else { return false }
            beginAttachFile(to: id)
        case .editLink:
            // One topic only (the Link / Note / Attachments submenus are
            // disabled for a multi-selection).
            guard let id = selectedID, scene.nodes[id] != nil, !isMultiSelection else { return false }
            beginEditLink(id)
        case .goBack:
            guard backTargetID != nil else { return false }
            goBack()
        case .toggleTaskDone:
            guard let id = selectedID, scene.nodes[id] != nil, task(of: id) != nil else { return false }
            if isMultiSelection { toggleTargetsDone() } else { toggleTaskDone(id) }
        case let .collapseToLevel(level): collapseToLevel(level)
        case .expandAll: expandAll()
        case .cancel:
            if boundaryMemberEditing != nil {
                finishEditBoundaryMembers(commit: false)
                return true
            }
            if isMultiSelection {
                collapseSelectionToPrimary()
                return true
            }
            guard pickMode != nil || selectedItem != nil else { return false }
            if pickMode != nil { cancelPick() } else { selectItem(nil) }
        }
        return true
    }
}
