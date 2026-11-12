import CoreGraphics
import Foundation

/// How a tap on a topic was handled (iPad touch scheme, WP11).
enum TouchTapOutcome: Equatable {
    /// Completed a relationship / attach / link pick.
    case picked
    /// The topic is being edited: the text field handles the tap.
    case ignored
    /// Select mode / member editing: toggled; palette scheduled.
    case toggled
    /// Selected; the palette shows after the double-tap interval.
    case selected
    /// Tap on the topic whose palette was showing: palette hidden.
    case hidPalette
    /// Double-tap: inline rename.
    case rename
}

/// iPad touch + Apple Pencil UX: single tap = select + floating action
/// palette, double-tap = rename, "+" handle = add child, Pencil double-tap /
/// squeeze / Scribble / hover. macOS keeps its click scheme (double-click =
/// add child); these entry points are only wired on iOS.
extension EditorController {
    // MARK: Palette visibility

    /// Editor states in which the palette and "+" handle stay hidden.
    var isTouchBusy: Bool {
        editingID != nil || labelEditing != nil || pickMode != nil || marquee != nil || drag != nil
            || boundaryMemberEditing != nil || controlDrag != nil || taskPanelDrag != nil
    }

    /// Palette on screen now (nil = hidden).
    var visiblePalette: ActionPaletteState.Mode? {
        let hasTopic = selectedID.map { scene.nodes[$0] != nil } ?? false
        return palette.visibleMode(hasSelection: hasTopic, isBusy: isTouchBusy)
    }

    var paletteContext: PaletteContext {
        guard let primary = selectedID, let info = scene.nodes[primary] else { return PaletteContext(count: 0) }
        let ids = selection
        let nodes = ids.compactMap(model.map.node(withID:))
        let reference = model.map.node(withID: primary)
        return PaletteContext(count: max(ids.count, 1), isMainRoot: primary == model.root.id,
                              isTreeRoot: info.isTreeRoot,
                              hasChildren: ids.count > 1 ? nodes.contains { !$0.children.isEmpty } : info.hasChildren,
                              isCollapsed: info.isCollapsed, isTask: reference?.task != nil,
                              isDoneTask: reference?.task?.isDone == true,
                              allTasks: !nodes.isEmpty && nodes.allSatisfy { $0.task != nil },
                              hasNote: info.attachments.contains { $0.kind == .markdown },
                              hasLink: info.link != nil,
                              hasMovable: !model.map.movableTopics(selectedIDs).isEmpty)
    }

    var paletteItems: [PaletteItem] {
        switch visiblePalette {
        case .selection?: return ActionPaletteCatalog.items(for: paletteContext)
        case .insert?: return ActionPaletteCatalog.insertItems(hasSelection: selectedID.map { scene.nodes[$0] != nil } ?? false)
        case nil: return []
        }
    }

    /// Shows the selection palette once the double-tap interval has passed.
    func scheduleSelectionPalette() {
        let token = palette.schedule()
        paletteScheduler(TapSequence.maxInterval) { [weak self] in self?.palette.fire(token) }
    }

    /// Pan / zoom started (hides the palette until `endCanvasGesture`).
    func beginCanvasGesture(_ interaction: ActionPaletteState.Interaction) {
        if !palette.interactions.contains(interaction) { palette.begin(interaction) }
    }

    func endCanvasGesture(_ interaction: ActionPaletteState.Interaction) {
        if palette.interactions.contains(interaction) { palette.end(interaction) }
    }

    /// A hardware-keyboard command ran: the palette is touch UI.
    func keyboardDidAct() {
        if palette.isRequested || palette.pendingToken != nil { palette.dismiss() }
    }

    // MARK: Taps

    /// Tap on a topic (iPad). `time` = uptime of the tap (tests pass it).
    @discardableResult
    func touchTapTopic(_ id: UUID, at location: CGPoint,
                       time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TouchTapOutcome {
        if completePick(id) {
            tapSequence.reset()
            return .picked
        }
        guard editingID != id else { return .ignored }
        if tapsToggleSelection {
            tapSequence.reset()
            clickTopic(id)
            if selectedID != nil { scheduleSelectionPalette() }
            return .toggled
        }
        let kind = tapSequence.classify(target: id, location: location, time: time)
        if kind == .double, !isRecentCheckboxClick(on: id) {
            palette.dismiss()
            beginEditing(id)
            return .rename
        }
        let wasShowing = visiblePalette == .selection && selectedIDs == [id]
        clickTopic(id)
        if wasShowing {
            palette.dismiss()
            return .hidPalette
        }
        scheduleSelectionPalette()
        return .selected
    }

    /// Tap on empty canvas (iPad): hides the palette (the canvas deselects).
    func touchTapBackground() {
        tapSequence.reset()
        palette.dismiss()
    }

    /// Long press on a topic: its context menu replaces the palette.
    func touchLongPress(_ id: UUID) {
        tapSequence.reset()
        palette.dismiss()
        if !isSelected(id), editingID != id { select(id) }
    }

    /// Rubber band (Select mode) finished: palette for the new selection.
    func touchMarqueeEnded() {
        if selectedID != nil { palette.showForSelection() }
    }

    /// "+" handle: add a child to `id` and name it.
    func tapAddChildHandle(_ id: UUID) {
        tapSequence.reset()
        guard scene.nodes[id] != nil else { return }
        if selectedIDs != [id] { select(id) }
        addChild()
    }

    /// Whether the "+" handle of `id` is shown (selected alone, or hovered by
    /// the Pencil / pointer).
    func showsAddChildHandle(_ id: UUID) -> Bool {
        guard scene.nodes[id] != nil, !isSelectMode, palette.interactions.isEmpty else { return false }
        return AddChildHandle.isShown(for: id, selection: selectedIDs, hoveredID: pencilHoveredID ?? hoveredID,
                                      editingID: editingID, isBusy: isTouchBusy)
    }

    /// Topic highlighted by the Pencil / pointer hover.
    func isHoverHighlighted(_ id: UUID) -> Bool {
        (pencilHoveredID ?? hoveredID) == id && editingID != id
    }

    /// Screen center of the "+" handle of `id` (beyond its collapse toggle).
    func addChildHandleCenter(for id: UUID) -> CGPoint? {
        guard let info = scene.nodes[id], let frame = screenFrame(of: id) else { return nil }
        // Same rule as the canvas uses to show `CollapseToggle`.
        let toggleShown = info.hasChildren && (info.isCollapsed || selectedID == id || hoveredID == id)
        let extent = AddChildHandle.toggleExtent(isShown: toggleShown, edge: info.badgeEdge,
                                                 isCollapsed: info.isCollapsed, hiddenCount: info.hiddenCount,
                                                 scale: viewport.scale)
        return AddChildHandle.center(frame: frame, edge: info.badgeEdge, toggleExtent: extent)
    }

    /// Pencil hover moved (nil = left the canvas / lifted away). Keeps the
    /// hovered topic while the Pencil is over its "+" handle.
    func pencilHover(at point: CGPoint?) {
        pencilHoverPoint = point
        if let point { lastPencilPoint = point }
        var id = point.flatMap(topic(atScreen:))
        if id == nil, let point, let previous = pencilHoveredID, let center = addChildHandleCenter(for: previous),
           AddChildHandle.contains(point, center: center) {
            id = previous
        }
        if pencilHoveredID != id { pencilHoveredID = id }
    }

    // MARK: Palette actions

    /// Runs a palette button; document changes are one undo step each.
    func performPaletteAction(_ action: PaletteAction) {
        var insertPoint: CGPoint?
        if case let .insert(point) = palette.mode {
            insertPoint = point
            palette.dismiss()
        }
        let primary = selectedID.flatMap { scene.nodes[$0] != nil ? $0 : nil }
        switch action {
        case .addChild:
            // Insert palette without a selection adds to the central topic.
            addChild()
        case .addSibling:
            addSibling()
        case .rename:
            guard let primary else { return }
            beginEditing(primary)
        case .delete:
            palette.dismiss()
            deleteSelection()
        case .note:
            palette.dismiss()
            openOrAddNote(primary)
        case .link:
            guard let primary else { return }
            palette.dismiss()
            beginEditLink(primary)
        case .task:
            guard let primary else { return }
            if isMultiSelection {
                let nodes = selection.compactMap(model.map.node(withID:))
                if nodes.allSatisfy({ $0.task != nil }) { toggleTargetsDone(primary) } else { convertToTask(primary) }
            } else if task(of: primary) == nil {
                convertToTask(primary)
            } else {
                toggleTaskDone(primary)
            }
        case .boundary:
            palette.dismiss()
            addBoundaryFromSelection()
        case .collapse:
            toggleCollapseTargets()
        case .more:
            break
        case .floatingTopic:
            palette.dismiss()
            addFloatingTopic(at: insertPoint)
        case .drawing:
            guard let primary else { return }
            palette.dismiss()
            addDrawing(to: primary)
        case .attachFile:
            guard let primary else { return }
            palette.dismiss()
            beginAttachFile(to: primary)
        case .relationship:
            guard let primary else { return }
            palette.dismiss()
            beginRelationship(from: primary)
        }
    }

    // MARK: Apple Pencil

    private var viewCenter: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    /// Barrel double-tap (UIPencilInteraction tap), honoring the user setting.
    @discardableResult
    func pencilDoubleTap(preference: PencilPreference) -> PencilMapAction? {
        let selected = selectedID.flatMap { scene.nodes[$0] != nil ? $0 : nil }
        let action = PencilPolicy.doubleTapAction(preference: preference, selectedID: selected,
                                                  isMultiSelection: isMultiSelection,
                                                  fallbackPoint: lastPencilPoint ?? viewCenter)
        if let action { apply(action) }
        return action
    }

    /// Pencil Pro squeeze (ended), honoring the user setting.
    /// - Parameter hoverPoint: hover location of the squeeze (screen).
    @discardableResult
    func pencilSqueeze(preference: PencilPreference, hoverPoint: CGPoint?) -> PencilMapAction? {
        let point = hoverPoint ?? pencilHoverPoint
        let selected = selectedID.flatMap { scene.nodes[$0] != nil ? $0 : nil }
        let action = PencilPolicy.squeezeAction(preference: preference, hoverPoint: point,
                                                topicAtHover: point.flatMap(topic(atScreen:)),
                                                selectedID: selected, lastPoint: lastPencilPoint,
                                                viewCenter: viewCenter)
        if let action { apply(action, toggles: true) }
        return action
    }

    /// - Parameter toggles: showing the palette that is already shown hides it.
    func apply(_ action: PencilMapAction, toggles: Bool = false) {
        tapSequence.reset()
        switch action {
        case let .addChild(id):
            if selectedIDs != [id] { select(id) }
            addChild()
        case .showPalette:
            if toggles, visiblePalette == .selection {
                palette.dismiss()
                return
            }
            commitEditing()
            palette.showForSelection()
        case let .selectAndShowPalette(id):
            if toggles, visiblePalette == .selection, isSelected(id) {
                palette.dismiss()
                return
            }
            commitEditing()
            if !isSelected(id) { select(id) }
            palette.showForSelection()
        case let .insertMenu(point):
            if toggles, case .insert? = visiblePalette {
                palette.dismiss()
                return
            }
            commitEditing()
            palette.showInsert(at: point)
        }
    }

    // MARK: Scribble (writing over a topic renames it)

    /// Topics whose screen frame meets `rect` (screen points).
    func scribbleTopics(inScreenRect rect: CGRect) -> [UUID] {
        guard viewport.scale > 0 else { return [] }
        let origin = viewport.toMap(rect.origin)
        let mapRect = CGRect(x: origin.x, y: origin.y, width: rect.width / viewport.scale,
                             height: rect.height / viewport.scale)
        return ScribbleTargets.topics(in: mapRect, frames: scene.layout.frames, order: scene.order)
    }

    func screenFrame(of id: UUID) -> CGRect? {
        scene.layout.frames[id].map(viewport.toScreen)
    }

    /// Scribble focuses a topic: inline editing with the text selected, so
    /// the handwriting replaces the title.
    func beginScribble(on id: UUID) {
        guard scene.nodes[id] != nil else { return }
        tapSequence.reset()
        if editingID != id { beginEditing(id) }
    }
}
