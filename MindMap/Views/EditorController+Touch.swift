import CoreGraphics
import Foundation

/// How a tap on a topic was handled (iPad touch scheme, WP11 + WP16).
enum TouchTapOutcome: Equatable {
    /// Completed a relationship / attach / link pick.
    case picked
    /// The topic is being edited: the text field handles the tap.
    case ignored
    /// Select mode / member editing: toggled; palette scheduled.
    case toggled
    /// Selected (no children to fold); the palette shows after the
    /// double-tap interval.
    case selected
    /// Tap on the leaf topic whose palette was showing: palette hidden.
    case hidPalette
    /// Selected and its collapsed branch expanded at once.
    case expanded
    /// Selected; its branch collapses after the double-tap interval unless
    /// a second tap makes it a double-tap.
    case collapsing
    /// The tap landed on a checkbox / link / attachment button of the topic,
    /// which handled it.
    case accessory
    /// Double-tap: a new child inside the topic, being named.
    case addedChild
    /// Double-tap on a read-only map (WP15): nothing added, notice shown.
    case refused
}

/// iPad touch + Apple Pencil UX: single tap = select + fold / unfold its
/// branch + floating action palette, double-tap = add a child inside (WP16;
/// rename via the palette's Edit, the context menu, Space / F2 / typing or
/// Scribble), "+" handle = add child, Pencil double-tap / squeeze / Scribble
/// / hover. macOS keeps its click scheme (double-click = add child); these
/// entry points are only wired on iOS.
extension EditorController {
    // MARK: Palette visibility

    /// Editor states in which the palette and "+" handle stay hidden.
    var isTouchBusy: Bool {
        editingID != nil || labelEditing != nil || pickMode != nil || marquee != nil || drag != nil
            || boundaryMemberEditing != nil || controlDrag != nil || taskPanelDrag != nil || favoritesPanelDrag != nil
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
                              hasMovable: !model.map.movableTopics(selectedIDs).isEmpty,
                              isReadOnly: isReadOnly)
    }

    var paletteItems: [PaletteItem] {
        switch visiblePalette {
        case .selection?: return ActionPaletteCatalog.items(for: paletteContext)
        case .insert?:
            // Nothing to insert into a read-only map (WP15).
            guard canEdit else { return [] }
            return ActionPaletteCatalog.insertItems(hasSelection: selectedID.map { scene.nodes[$0] != nil } ?? false)
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
            // Select mode: taps build the selection, never fold.
            tapSequence.reset()
            clickTopic(id)
            if selectedID != nil { scheduleSelectionPalette() }
            return .toggled
        }
        let command = hardwareModifiers.contains(.command), shift = hardwareModifiers.contains(.shift)
        if command || shift {
            // Hardware keyboard: ⌘-tap toggles, ⇧-tap extends (as on the Mac).
            tapSequence.reset()
            clickTopic(id, command: command, shift: shift)
            if selectedID != nil { scheduleSelectionPalette() }
            return .toggled
        }
        if TopicAccessoryTap.isAccessory(lastAccessoryTap, id: id, time: time) {
            // The checkbox / link / attachment button did its job (and
            // selected); the tap neither folds nor starts a double-tap.
            tapSequence.reset()
            return .accessory
        }
        let kind = tapSequence.classify(target: id, location: location, time: time)
        if kind == .double { return doubleTapAddChild(id) }
        settlePendingTapCollapse(before: id)
        let wasShowing = visiblePalette == .selection && selectedIDs == [id]
        clickTopic(id)
        guard let info = scene.nodes[id] else { return .selected }
        switch TopicTapPlan.plan(hasChildren: info.hasChildren, isCollapsed: info.isCollapsed,
                                 isMainRoot: id == model.root.id) {
        case .select:
            if wasShowing {
                palette.dismiss()
                return .hidPalette
            }
            scheduleSelectionPalette()
            return .selected
        case .expandNow:
            // Palette hidden now, back after the expand has animated
            // (`TapSequence.maxInterval` > `relayoutDuration`).
            scheduleSelectionPalette()
            toggleCollapse(id)
            return .expanded
        case .collapseLater:
            let paletteToken = palette.schedule()
            tapCollapseCounter += 1
            let token = tapCollapseCounter
            pendingTapCollapse = PendingTapCollapse(id: id, token: token, paletteToken: paletteToken)
            paletteScheduler(TapSequence.maxInterval) { [weak self] in self?.firePendingTapCollapse(token) }
            return .collapsing
        }
    }

    /// Second tap of a double-tap: the first tap's collapse never happens,
    /// the topic is expanded (it already is when the first tap expanded it)
    /// and gets a new child being named, keyboard / Scribble ready. The
    /// tapped topic stays where it is on screen.
    private func doubleTapAddChild(_ id: UUID) -> TouchTapOutcome {
        cancelPendingTapCollapse()
        palette.dismiss()
        // Read-only map (WP15): no child; the notice says why.
        guard requireEditable() else { return .refused }
        if selectedIDs != [id] || selectedID != id { select(id) }
        // `addChild` expands a collapsed parent in the same undo step.
        keepingOnScreen(id) { addChild() }
        if let child = editingID { reveal(child) }
        return .addedChild
    }

    /// The deferred collapse of a single tap (`TopicTapPlan.collapseLater`):
    /// runs unless a double-tap / toggle cancelled it or the topic changed
    /// meanwhile; the palette follows once the map has settled.
    func firePendingTapCollapse(_ token: Int) {
        guard let pending = pendingTapCollapse, pending.token == token else { return }
        pendingTapCollapse = nil
        collapseFromTap(pending)
    }

    private func collapseFromTap(_ pending: PendingTapCollapse) {
        guard editingID == nil, drag == nil, let info = scene.nodes[pending.id], info.hasChildren,
              !info.isCollapsed else {
            palette.fire(pending.paletteToken)
            return
        }
        toggleCollapse(pending.id)
        validateSelection()
        let paletteToken = pending.paletteToken
        paletteScheduler(Self.relayoutDuration) { [weak self] in self?.palette.fire(paletteToken) }
    }

    /// A tap on another topic confirms the pending one was a single tap:
    /// its collapse runs now (unless the new tap is inside that branch,
    /// which the collapse would hide).
    private func settlePendingTapCollapse(before id: UUID) {
        guard let pending = pendingTapCollapse, pending.id != id else { return }
        pendingTapCollapse = nil
        if model.map.node(withID: pending.id)?.contains(id) == true { return }
        collapseFromTap(pending)
    }

    func cancelPendingTapCollapse() {
        pendingTapCollapse = nil
    }

    /// The "+N" / "−" toggle beside a topic (iPad): one toggle, also when a
    /// tap on the topic just scheduled its collapse.
    func tapCollapseToggle(_ id: UUID) {
        tapSequence.reset()
        let pending = pendingTapCollapse
        cancelPendingTapCollapse()
        toggleCollapse(id)
        // The topic tap's palette still comes, after the relayout.
        if let token = pending?.paletteToken {
            paletteScheduler(Self.relayoutDuration) { [weak self] in self?.palette.fire(token) }
        }
    }

    /// A button inside topic `id` was tapped (task checkbox, link icon,
    /// attachment icon): the topic's own tap recognizer ignores this tap.
    func noteAccessoryTap(on id: UUID, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastAccessoryTap = (id, time)
    }

    /// Tap on empty canvas (iPad): hides the palette (the canvas deselects).
    func touchTapBackground() {
        tapSequence.reset()
        palette.dismiss()
    }

    /// Long press on a topic: its context menu replaces the palette.
    func touchLongPress(_ id: UUID) {
        tapSequence.reset()
        cancelPendingTapCollapse()
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
        cancelPendingTapCollapse()
        guard scene.nodes[id] != nil else { return }
        if selectedIDs != [id] { select(id) }
        addChild()
    }

    /// Whether the "+" handle of `id` is shown (selected alone, or hovered by
    /// the Pencil / pointer).
    func showsAddChildHandle(_ id: UUID) -> Bool {
        guard scene.nodes[id] != nil, !isSelectMode, palette.interactions.isEmpty, canEdit else { return false }
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
        // Read-only map (WP15): edit buttons are disabled; Link = Go to.
        if action.isEdit, !requireEditable() { return }
        if action == .link, isReadOnly {
            palette.dismiss()
            if let primary, model.map.resolvedLink(of: primary) != nil { goToLink(of: primary) } else { showReadOnlyNotice() }
            return
        }
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
        cancelPendingTapCollapse()
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
        // Read-only map (WP15): Scribble does not rename topics.
        guard viewport.scale > 0, canEdit else { return [] }
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
        guard scene.nodes[id] != nil, requireEditable() else { return }
        tapSequence.reset()
        cancelPendingTapCollapse()
        if editingID != id { beginEditing(id) }
    }
}
