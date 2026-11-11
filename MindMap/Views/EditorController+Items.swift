import SwiftUI

/// Floating topics, relationships and boundaries. Each document change is
/// one undo step via `MindMapModel`.
extension EditorController {
    static let floatingTopicText = "Floating Topic"
    /// Hit tolerance (screen points) for lines and outlines.
    static let hitTolerance: CGFloat = 8

    func itemExists(_ item: CanvasItem) -> Bool {
        switch item {
        case let .relationship(id): return scene.layout.relationships[id] != nil
        case let .boundary(id): return scene.layout.boundaries[id] != nil
        }
    }

    func relationship(_ id: UUID) -> Relationship? {
        model.map.relationships.first { $0.id == id }
    }

    func boundary(_ id: UUID) -> Boundary? {
        model.map.boundaries.first { $0.id == id }
    }

    // MARK: Floating topics

    /// Adds a floating topic centered at `screenPoint` (default: a free spot
    /// near the view center) and starts naming it (one undo step).
    func addFloatingTopic(at screenPoint: CGPoint? = nil) {
        commitEditing()
        cancelPick()
        var position = viewport.toMap(screenPoint ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        if screenPoint == nil {
            let probe = CGSize(width: 140, height: 44)
            for _ in 0..<30 {
                let rect = CGRect(x: position.x - probe.width / 2, y: position.y - probe.height / 2,
                                  width: probe.width, height: probe.height)
                guard scene.layout.frames.values.contains(where: { $0.intersects(rect) }) else { break }
                position.y += probe.height + 16
            }
        }
        guard let id = model.addFloating(at: position, text: Self.floatingTopicText, undoManager: undoManager) else {
            return
        }
        startEditingNew(id)
    }

    /// Detaches a tree topic (with subtree) into a floating topic where it is.
    func detachAsFloating(_ id: UUID) {
        commitEditing()
        guard id != model.root.id, !model.map.isFloatingRoot(id), let frame = scene.layout.frames[id] else { return }
        let position = CGPoint(x: frame.midX + 24, y: frame.midY + 24)
        if model.detach(id, to: position, undoManager: undoManager) { select(id) }
    }

    func beginAttach(_ id: UUID) {
        guard model.map.isFloatingRoot(id) else { return }
        beginPick(.attach(id))
    }

    // MARK: Picking a target (relationship / attach)

    func beginRelationship(from id: UUID) {
        guard scene.nodes[id] != nil else { return }
        beginPick(.relationship(from: id))
    }

    private func beginPick(_ mode: PickMode) {
        commitEditing()
        select(mode.sourceID)
        pickPointer = nil
        pickMode = mode
    }

    func cancelPick() {
        if pickMode != nil { pickMode = nil }
        if pickPointer != nil { pickPointer = nil }
    }

    /// Topic under the pointer while picking (highlighted as target).
    var pickHoverID: UUID? {
        guard let pickMode, let pickPointer else { return nil }
        let excluded: Set<UUID>
        switch pickMode {
        case let .relationship(from): excluded = [from]
        case let .attach(id): excluded = Set(model.map.node(withID: id)?.allIDs ?? [id])
        }
        return DropTargetFinder.target(at: viewport.toMap(pickPointer), frames: scene.layout.frames,
                                       excluding: excluded)
    }

    /// Completes picking with `target`; returns true if the tap was consumed.
    @discardableResult
    func completePick(_ target: UUID) -> Bool {
        guard let mode = pickMode else { return false }
        cancelPick()
        switch mode {
        case let .relationship(from):
            guard target != from,
                  let id = model.addRelationship(from: from, to: target, undoManager: undoManager) else { return true }
            selectItem(.relationship(id))
        case let .attach(id):
            if model.reparent(id, to: target, undoManager: undoManager) { select(id) }
        }
        return true
    }

    // MARK: Secondary click (select before the context menu)

    /// Selects whatever is under `screenPoint` (macOS right click).
    func selectForContextMenu(at screenPoint: CGPoint) {
        contextPoint = screenPoint
        cancelPick()
        let hit = CanvasHitTester.hit(at: viewport.toMap(screenPoint), layout: scene.layout, map: model.map,
                                      tolerance: Self.hitTolerance / viewport.scale)
        switch hit {
        case let .node(id): if selectedID != id { select(id) }
        case let .item(item): if selectedItem != item { selectItem(item) }
        case nil: break
        }
    }

    // MARK: Relationship / boundary common

    func removeItem(_ item: CanvasItem) {
        switch item {
        case let .relationship(id): model.removeRelationship(id, undoManager: undoManager)
        case let .boundary(id): model.removeBoundary(id, undoManager: undoManager)
        }
        if selectedItem == item { selectedItem = nil }
    }

    /// Starts inline editing of the item's label (shown on the canvas).
    func beginLabelEdit(_ item: CanvasItem) {
        selectItem(item)
        cancelPick()
        let text: String?
        switch item {
        case let .relationship(id): text = relationship(id)?.label
        case let .boundary(id): text = boundary(id)?.label
        }
        setLabelEditing(item, text: text ?? "")
    }

    /// Commits the inline label draft (one undo step if changed). With
    /// `item`, only if that item is still the one being edited.
    func commitLabelEdit(ifEditing item: CanvasItem? = nil) {
        guard let editing = labelEditing, item == nil || item == editing else { return }
        let text = labelDraft
        setLabelEditing(nil, text: "")
        setLabel(text, for: editing)
    }

    func cancelLabelEdit() {
        setLabelEditing(nil, text: "")
    }

    /// Sets (empty clears) the label: one undo step if it changed.
    func setLabel(_ text: String, for item: CanvasItem) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String? = trimmed.isEmpty ? nil : trimmed
        switch item {
        case let .relationship(id):
            guard let relationship = relationship(id), relationship.label != label else { return }
            model.relabelRelationship(id, to: label, undoManager: undoManager)
        case let .boundary(id):
            guard let boundary = boundary(id), boundary.label != label else { return }
            model.updateBoundary(id, label: label, colorHex: boundary.colorHex, undoManager: undoManager)
        }
    }

    // MARK: Relationships

    func updateRelationshipStyle(_ id: UUID, _ change: (inout RelationshipStyle) -> Void) {
        guard var style = relationship(id)?.style else { return }
        let old = style
        change(&style)
        guard style != old else { return }
        model.setRelationshipStyle(style, for: id, undoManager: undoManager)
    }

    func setRelationshipColor(_ hex: String?, for id: UUID) {
        updateRelationshipStyle(id) { $0.colorHex = hex }
    }

    func resetRelationshipCurve(_ id: UUID) {
        guard let relationship = relationship(id),
              relationship.fromControlOffset != nil || relationship.toControlOffset != nil else { return }
        model.setRelationshipControlOffsets(id, from: nil, to: nil, undoManager: undoManager)
    }

    /// Geometry to draw (map coordinates), including a live handle drag.
    func relationshipPath(_ id: UUID) -> RelationshipPath? {
        guard let path = scene.layout.relationships[id] else { return nil }
        guard let drag = controlDrag, drag.relationshipID == id else { return path }
        let dx = drag.translation.width / viewport.scale, dy = drag.translation.height / viewport.scale
        var c1 = path.control1, c2 = path.control2
        if drag.isStart {
            c1 = CGPoint(x: c1.x + dx, y: c1.y + dy)
        } else {
            c2 = CGPoint(x: c2.x + dx, y: c2.y + dy)
        }
        return RelationshipCurve.withControls(path, control1: c1, control2: c2)
    }

    func updateControlDrag(_ id: UUID, isStart: Bool, translation: CGSize) {
        controlDrag = ControlPointDrag(relationshipID: id, isStart: isStart, translation: translation)
    }

    /// Stores the dragged curve as control offsets (one undo step).
    func endControlDrag() {
        guard let drag = controlDrag else { return }
        defer { controlDrag = nil }
        guard let path = relationshipPath(drag.relationshipID), drag.translation != .zero else { return }
        model.setRelationshipControlOffsets(
            drag.relationshipID,
            from: CGVector(dx: path.control1.x - path.start.x, dy: path.control1.y - path.start.y),
            to: CGVector(dx: path.control2.x - path.end.x, dy: path.control2.y - path.end.y),
            undoManager: undoManager
        )
    }

    // MARK: Boundaries

    func addBoundary(around id: UUID) {
        commitEditing()
        guard id != model.root.id, let boundary = model.addBoundary(around: id, undoManager: undoManager) else {
            return
        }
        selectItem(.boundary(boundary))
    }

    func setBoundaryColor(_ hex: String?, for id: UUID) {
        guard let boundary = boundary(id), boundary.colorHex != hex else { return }
        model.updateBoundary(id, label: boundary.label, colorHex: hex, undoManager: undoManager)
    }

    /// Effective outline color of a boundary.
    func boundaryColorHex(_ boundary: Boundary) -> String {
        boundary.colorHex ?? scene.colors[boundary.nodeID] ?? ColorTheme.rootColorHex
    }
}
