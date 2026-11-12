import SwiftUI

/// User actions. Each document change is one undo step on `undoManager`.
extension EditorController {
    // MARK: Selection

    func select(_ id: UUID?) {
        commitLabelEdit()
        if let editingID, editingID != id { commitEditing() }
        selectedID = id
        selectedItem = nil
    }

    /// Selects a relationship / boundary (deselects topics).
    func selectItem(_ item: CanvasItem?) {
        commitEditing()
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
        guard let id = selectedID, id != model.root.id else { return }
        let next = model.map.isFloatingRoot(id) ? nil : model.map.tree(containing: id)?.selectionAfterDeleting(id)
        if model.delete(id, undoManager: undoManager) { selectedID = next }
    }

    func toggleCollapse(_ id: UUID? = nil) {
        guard let id = id ?? selectedID, scene.nodes[id]?.hasChildren == true else { return }
        commitEditing()
        model.toggleCollapse(id, undoManager: undoManager)
    }

    // MARK: Inline editing

    /// Starts editing `id` (default: selection). `replacement` replaces the
    /// text (typing on a selected node); otherwise all text is selected.
    func beginEditing(_ id: UUID? = nil, replacement: String? = nil) {
        guard let id = id ?? selectedID, let node = model.map.node(withID: id) else { return }
        if let editingID, editingID != id { commitEditing() }
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
        if editingID != nil { commitEditing() }
        cancelPick()
        let point = viewport.toMap(location)
        let excluded = Set(model.map.node(withID: id)?.allIDs ?? [id])
        let target = freeMove ? nil
            : DropTargetFinder.target(at: point, frames: scene.layout.frames, excluding: excluded)
        var drag = NodeDrag(id: id, translation: translation, targetID: target)
        drag.freeMove = freeMove
        if let target, let frame = scene.layout.frames[target], scene.nodes[target]?.isTreeRoot == false {
            drag.siblingAxis = scene.siblingAxis(of: target)
            drag.placement = DropTargetFinder.placement(at: point, in: frame, siblingAxis: drag.siblingAxis)
        }
        self.drag = drag
        selectedID = id
        selectedItem = nil
    }

    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        if let target = drag.targetID {
            switch drag.placement {
            case .child:
                if model.map.parentID(of: drag.id) != target {
                    model.reparent(drag.id, to: target, undoManager: undoManager)
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

    /// Offset of the dropped topic's center from its parent's center (map points).
    func freePosition(for drag: NodeDrag) -> CGPoint? {
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
        guard index != movingIndex else { return }
        model.reparent(id, to: parent, at: index, undoManager: undoManager)
    }

    // MARK: Format

    /// Sets the layout of a topic's children (nil = inherit); the scene is
    /// rebuilt from the new map at once and the topic stays in view.
    func setLayoutStyle(_ style: LayoutStyle?, for id: UUID? = nil) {
        guard let id = id ?? selectedID else { return }
        commitEditing()
        guard model.setLayoutStyle(style, for: id, undoManager: undoManager) else { return }
        reveal(id)
    }

    /// Clears color tag and custom color (one undo step).
    func resetColor(_ id: UUID, wholeBranch: Bool) {
        let map = model.map
        guard let tagEdits = try? map.setAttributeEdits(.colorTag(.none), for: id, wholeBranch: wholeBranch),
              let customEdits = try? map.setAttributeEdits(.customColor(nil), for: id, wholeBranch: wholeBranch)
        else { return }
        model.perform(tagEdits + customEdits, actionName: "Reset Color", undoManager: undoManager)
    }

    func applyColorSheet(_ request: ColorSheetRequest, hex: String) {
        switch request.target {
        case let .node(id, wholeBranch):
            model.setCustomColor(hex, for: id, wholeBranch: wholeBranch, undoManager: undoManager)
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
        viewport = .fitting(scene.layout.bounds, in: viewSize)
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
        switch command {
        case .addChild: addChild()
        case .addSibling: addSibling()
        case .delete: deleteSelection()
        case .edit where selectedItem != nil:
            beginLabelEdit(selectedItem!)
        case .edit, .editReplacing:
            guard selectedID != nil else { return false }
            if case let .editReplacing(text) = command { beginEditing(replacement: text) } else { beginEditing() }
        case .toggleCollapse: toggleCollapse()
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
            guard let id = selectedID else { return false }
            addBoundary(around: id)
        case .note:
            guard let id = selectedID, scene.nodes[id] != nil else { return false }
            openOrAddNote(id)
        case .handwrittenNote:
            guard let id = selectedID, scene.nodes[id] != nil else { return false }
            openOrAddDrawing(id)
        case .attachFile:
            guard let id = selectedID, scene.nodes[id] != nil else { return false }
            beginAttachFile(to: id)
        case .editLink:
            guard let id = selectedID, scene.nodes[id] != nil else { return false }
            beginEditLink(id)
        case .goBack:
            guard backTargetID != nil else { return false }
            goBack()
        case let .collapseToLevel(level): collapseToLevel(level)
        case .expandAll: expandAll()
        case .cancel:
            guard pickMode != nil || selectedItem != nil else { return false }
            if pickMode != nil { cancelPick() } else { selectItem(nil) }
        }
        return true
    }
}
