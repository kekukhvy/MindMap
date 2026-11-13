import SwiftUI

/// The mind-map canvas: pan/zoom, branch lines, topics, gestures, keyboard.
struct CanvasView: View {
    @Bindable var editor: EditorController
    @FocusState private var isFocused: Bool
    @State private var pinchStart: Viewport?
    @State private var panStart: Viewport?
    /// What the current background drag does (decided when it starts).
    @State private var backgroundDrag: BackgroundDragMode?
    /// Edited topic whose border is pressed: keeps `editingDragHandle`
    /// alive when the press ends editing (focus leaves the text field).
    @GestureState private var pressedHandleID: UUID?

    static let space = "mindmap.canvas"

    var body: some View {
        GeometryReader { proxy in
            let scene = editor.scene
            let viewport = editor.viewport
            ZStack(alignment: .topLeading) {
                background
                ZStack(alignment: .topLeading) {
                    BoundariesLayer(editor: editor, viewport: viewport)
                    ConnectorsLayer(connectors: editor.drawnConnectors, viewport: viewport)
                    ForEach(scene.order, id: \.self) { id in
                        node(id, scene: scene, viewport: viewport)
                    }
                    ForEach(scene.order, id: \.self) { id in
                        collapseToggle(id, scene: scene, viewport: viewport)
                    }
                    #if os(iOS)
                    ForEach(scene.order, id: \.self) { id in
                        addChildHandle(id)
                    }
                    #endif
                    editingDragHandle(scene: scene, viewport: viewport)
                    RelationshipsLayer(editor: editor, viewport: viewport)
                    // Virtual Tasks card (not a topic / not in the layout).
                    if let panel = editor.taskPanel {
                        TasksPanelView(editor: editor, panel: panel, viewport: viewport)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .animation(.snappy(duration: 0.25), value: editor.model.map)
                CanvasOverlays(editor: editor, viewport: viewport)
                #if os(iOS)
                ActionPaletteLayer(editor: editor, viewport: viewport)
                #endif
            }
            // White XMind paper in dark mode too: topic colors assume it.
            .environment(\.colorScheme, .light)
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    PickBanner(editor: editor)
                    SelectionBanner(editor: editor)
                    ReadOnlyNoticeView(editor: editor)
                }
            }
            .overlay(alignment: .bottom) { BackPill(editor: editor) }
            .onContinuousHover(coordinateSpace: .named(CanvasView.space)) { phase in
                guard editor.pickMode != nil else { return }
                if case let .active(location) = phase { editor.pickPointer = location } else { editor.pickPointer = nil }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(.named(CanvasView.space))
            .clipped()
            .contentShape(Rectangle())
            // Files from Finder / Files / other apps: onto a topic = attach.
            .onDrop(of: [.item], delegate: FileDropDelegate(editor: editor))
            .simultaneousGesture(magnify)
            .onAppear { editor.updateViewSize(proxy.size) }
            .onChange(of: proxy.size) { _, size in editor.updateViewSize(size) }
        }
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($isFocused)
        #if os(macOS)
        // Edit ▸ Copy / Cut / Paste (⌘C / ⌘X / ⌘V): topics with their
        // subtrees; Paste also takes text (lines → topics) and files /
        // images (attached, WP6).
        .onCopyCommand { editor.copySelection() ? TopicPasteboard.itemProviders() : [] }
        .onCutCommand { editor.cutSelection() ? TopicPasteboard.itemProviders() : [] }
        .onPasteCommand(of: [.mindMapTopics, .fileURL, .image, .pdf, .plainText]) { _ in editor.paste() }
        #endif
        // Published only while the canvas (or its inline editor) has focus, so
        // plain-key menu shortcuts never steal keys from other text inputs.
        .focusedValue(\.mindMapCommandState, editor.commandState)
        .mindMapKeyboard(editor)
        .onAppear {
            isFocused = true
            #if os(iOS)
            presentGestureHelpOnFirstLaunch()
            #if DEBUG
            DebugTouchActions.run(editor)
            #endif
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $editor.isGestureHelpPresented) {
            GestureHelpSheet()
                .gestureHelpSizing()
        }
        #endif
        .onChange(of: editor.editingID) { _, id in
            if id == nil { isFocused = true }
        }
        .onChange(of: editor.labelEditing) { _, item in
            if item == nil { isFocused = true }
        }
    }

    // MARK: Background (pan, deselect, scroll wheel)

    private var background: some View {
        Color.canvasBackground
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named(CanvasView.space)).onEnded {
                guard editor.pickMode == nil else { return }
                editor.addFloatingTopic(at: $0.location)
            })
            .simultaneousGesture(TapGesture().onEnded {
                #if os(iOS)
                editor.touchTapBackground()
                #endif
                editor.cancelPick()
                // Editing boundary members: only topic clicks count.
                if editor.boundaryMemberEditing == nil { editor.select(nil) }
                isFocused = true
            })
            .gesture(pan)
            #if os(macOS)
            .contextMenu { CanvasBackgroundMenu(editor: editor) }
            #endif
            #if os(iOS)
            .background(PencilBridge(editor: editor))
            .background(TabKeyBridge(isActive: isFocused || editor.editingID != nil) {
                editor.keyboardDidAct()
                if editor.editingID != nil {
                    editor.commitEditing()
                    editor.addChild()
                } else if isFocused {
                    editor.addChild()
                }
            })
            .background(ScrollPanBridge { dx, dy in editor.viewport.pan(dx: dx, dy: dy) })
            #endif
            #if os(macOS)
            .background(ScrollWheelHandler(onScroll: { delta, location, zoom in
                if zoom {
                    editor.viewport.zoom(to: editor.viewport.scale * exp(delta.height * 0.01), around: location)
                } else {
                    editor.viewport.pan(dx: delta.width, dy: delta.height)
                }
            }, onSecondaryClick: { location in
                editor.selectForContextMenu(at: location)
            }))
            #endif
    }

    /// Background drag: pans; with ⇧ or ⌘ held (iPad: Select mode) it
    /// draws a rubber band that adds the touched topics to the selection.
    private var pan: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                if backgroundDrag == nil {
                    backgroundDrag = editor.tapsToggleSelection || Self.isSelectionModifierPressed ? .marquee : .pan
                }
                if backgroundDrag == .marquee {
                    editor.updateMarquee(from: value.startLocation, to: value.location)
                    return
                }
                editor.beginCanvasGesture(.pan)
                let start = panStart ?? editor.viewport
                if panStart == nil { panStart = start }
                var viewport = start
                viewport.pan(dx: value.translation.width, dy: value.translation.height)
                editor.viewport = viewport
            }
            .onEnded { _ in
                if backgroundDrag == .marquee {
                    editor.endMarquee()
                    #if os(iOS)
                    editor.touchMarqueeEnded()
                    #endif
                }
                editor.endCanvasGesture(.pan)
                backgroundDrag = nil
                panStart = nil
                isFocused = true
            }
    }

    private enum BackgroundDragMode { case pan, marquee }

    /// ⇧ or ⌘ held for the current mouse event (macOS; synthesized events too).
    private static var isSelectionModifierPressed: Bool { isCommandClick || isShiftClick }

    /// Shift held for the current click (macOS; synthesized events too).
    private static var isShiftClick: Bool {
        #if os(macOS)
        NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            || ScrollWheelHandler.lastMouseModifiers.contains(.shift)
        #else
        false
        #endif
    }

    private static var isOptionPressed: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option) || ScrollWheelHandler.lastMouseModifiers.contains(.option)
        #else
        false
        #endif
    }

    /// Command held for the current click (macOS; synthesized events too).
    private static var isCommandClick: Bool {
        #if os(macOS)
        NSApp.currentEvent?.modifierFlags.contains(.command) == true
            || ScrollWheelHandler.lastMouseModifiers.contains(.command)
        #else
        false
        #endif
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                editor.beginCanvasGesture(.zoom)
                let start = pinchStart ?? editor.viewport
                if pinchStart == nil { pinchStart = start }
                var viewport = start
                viewport.zoom(to: start.scale * value.magnification, around: value.startLocation)
                editor.viewport = viewport
            }
            .onEnded { _ in
                pinchStart = nil
                editor.endCanvasGesture(.zoom)
            }
    }

    // MARK: Topics

    @ViewBuilder
    private func node(_ id: UUID, scene: MapScene, viewport: Viewport) -> some View {
        if let info = scene.nodes[id], let frame = scene.layout.frames[id] {
            let screen = viewport.toScreen(frame)
            // Dragged topics (the whole selection) follow the pointer as ghosts.
            let drag = editor.drag.flatMap { $0.id == id || $0.ghostIDs.contains(id) ? $0 : nil }
            NodeView(info: info, scale: viewport.scale, isSelected: editor.isSelected(id),
                     isPrimarySelection: editor.selectedID == id, isHovered: isHoverHighlighted(id),
                     isDropTarget: editor.drag?.parentTargetID == id || editor.pickHoverID == id
                         || editor.fileDropTargetID == id,
                     editor: editor.editingID == id ? editor : nil, nodeID: id,
                     onOpenAttachment: { attachmentID in
                         editor.noteAccessoryTap(on: id)
                         editor.select(id)
                         editor.openAttachment(attachmentID)
                     },
                     onFollowLink: {
                         editor.noteAccessoryTap(on: id)
                         editor.goToLink(of: id)
                     },
                     onToggleTask: {
                         // Checkbox: toggles (one undo step) and selects the
                         // topic, like any click on it; never starts a drag.
                         editor.noteAccessoryTap(on: id)
                         editor.lastCheckboxClick = (id, Date())
                         editor.select(id)
                         editor.toggleTaskDone(id)
                         isFocused = true
                     })
                .frame(width: screen.width, height: screen.height)
                .contentShape(Rectangle())
                .opacity(drag == nil ? 1 : 0.75)
                .offset(drag?.translation ?? .zero)
                .zIndex(drag == nil ? 0 : 1)
                .position(x: screen.midX, y: screen.midY)
                .gesture(reparentDrag(id), including: id == editor.model.root.id ? .subviews : .all)
                #if os(macOS)
                // Double-click = new child (being named); rename via the
                // context menu, Space, F2 or typing.
                .onTapGesture(count: 2) {
                    guard editor.pickMode == nil, editor.editingID != id, !editor.tapsToggleSelection,
                          !Self.isSelectionModifierPressed, !editor.isRecentCheckboxClick(on: id) else { return }
                    editor.select(id)
                    editor.addChild()
                }
                .onHover { inside in editor.setHovered(id, inside) }
                .help(info.link?.topicHelp ?? "")
                .simultaneousGesture(TapGesture().onEnded {
                    if editor.completePick(id) { return }
                    // Cmd+click always toggles multi-selection (also on
                    // linked topics), Shift+click adds. Links open only via
                    // the link icon or the Link menu.
                    editor.clickTopic(id, command: Self.isCommandClick, shift: Self.isShiftClick)
                    if editor.editingID == nil { isFocused = true }
                })
                #else
                .onHover { inside in editor.setHovered(id, inside) }
                .help(info.link?.topicHelp ?? "")
                // iPad (WP16): tap = select + fold / unfold + action palette,
                // double-tap = add a child inside (`EditorController
                // .touchTapTopic`; one tap recognizer, so the first tap is
                // never delayed). Finger and Pencil taps alike. Handled on
                // the next main-queue turn: a checkbox / link / attachment
                // button inside the topic has then run its action and noted
                // itself (`noteAccessoryTap`), whichever recognizer fired first.
                .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(CanvasView.space)).onEnded { value in
                    let time = ProcessInfo.processInfo.systemUptime
                    DispatchQueue.main.async {
                        editor.touchTapTopic(id, at: value.location, time: time)
                        if editor.editingID == nil { isFocused = true }
                    }
                })
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                    editor.touchLongPress(id)
                })
                #endif
                .contextMenu {
                    NodeContextMenu(editor: editor, id: id)
                }
                .popover(isPresented: dueDatePickerBinding(id), arrowEdge: .bottom) {
                    DueDatePicker(editor: editor, id: id)
                }
        }
    }

    /// Pencil / pointer hover highlight (iPad only: macOS shows hover by
    /// the collapse toggle alone, unchanged).
    private func isHoverHighlighted(_ id: UUID) -> Bool {
        #if os(iOS)
        editor.isHoverHighlighted(id)
        #else
        false
        #endif
    }

    #if os(iOS)
    /// "+" on the child side of the selected / Pencil-hovered topic.
    @ViewBuilder
    private func addChildHandle(_ id: UUID) -> some View {
        if editor.showsAddChildHandle(id), let center = editor.addChildHandleCenter(for: id) {
            AddChildHandleView(center: center, onTap: {
                editor.tapAddChildHandle(id)
            }, onHover: { inside in editor.setHovered(id, inside) })
            .transition(.opacity)
        }
    }

    /// The compact Gestures sheet once, on the first launch.
    private func presentGestureHelpOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard GestureHelp.shouldShowOnLaunch(defaults: defaults, environment: ProcessInfo.processInfo.environment,
                                             isTesting: LaunchEnvironment.isTesting) else { return }
        defaults.set(true, forKey: GestureHelp.shownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { editor.isGestureHelpPresented = true }
    }
    #endif

    private func dueDatePickerBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { editor.dueDatePickerID == id },
                set: { if !$0, editor.dueDatePickerID == id { editor.dueDatePickerID = nil } })
    }

    @ViewBuilder
    private func collapseToggle(_ id: UUID, scene: MapScene, viewport: Viewport) -> some View {
        if let info = scene.nodes[id], info.hasChildren, editor.drag?.id != id,
           info.isCollapsed || editor.selectedID == id || editor.hoveredID == id,
           let frame = scene.layout.frames[id] {
            CollapseToggle(info: info, frame: viewport.toScreen(frame), scale: viewport.scale,
                           onToggle: {
                               #if os(iOS)
                               editor.tapCollapseToggle(id)
                               #else
                               editor.toggleCollapse(id)
                               #endif
                           },
                           onHover: { inside in editor.setHovered(id, inside) })
        }
    }

    /// While a topic is edited its text field owns the mouse, and SwiftUI
    /// does not run the topic's own drag gesture around a focused field: a
    /// transparent frame (topic rect minus the text area) on top keeps the
    /// edited topic draggable by its border/padding.
    @ViewBuilder
    private func editingDragHandle(scene: MapScene, viewport: Viewport) -> some View {
        if let id = pressedHandleID ?? editor.editingID, id != editor.model.root.id, let info = scene.nodes[id],
           let frame = scene.layout.frames[id] {
            let screen = viewport.toScreen(frame)
            let inset = CGSize(width: max(info.appearance.paddingH * viewport.scale - 1, 3),
                               height: max(info.appearance.paddingV * viewport.scale - 1, 3))
            Color.clear
                .frame(width: screen.width, height: screen.height)
                .contentShape(FrameRing(inset: inset), eoFill: true)
                .position(x: screen.midX, y: screen.midY)
                .gesture(handleDrag(id))
        }
    }

    /// Press (distance 0, so the handle survives the focus change) that
    /// becomes a topic drag after 6 pt.
    private func handleDrag(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasView.space))
            .updating($pressedHandleID) { _, state, _ in state = id }
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height)
                guard moved >= 6 || editor.drag?.id == id else { return }
                editor.updateDrag(id, translation: value.translation, location: value.location,
                                  freeMove: Self.isOptionPressed)
            }
            .onEnded { _ in
                if editor.drag?.id == id { editor.endDrag() } else { editor.select(id) }
                isFocused = true
            }
    }

    /// Drags a topic (also one being edited: the drag commits the text).
    /// Option-drag (macOS) always moves freely, even over other topics.
    private func reparentDrag(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                // Read-only map (WP15): the topic stays, the canvas pans
                // (and the notice says why nothing moved).
                if editor.isReadOnly, editor.drag == nil {
                    lockedPan(value)
                    return
                }
                editor.updateDrag(id, translation: value.translation, location: value.location,
                                  freeMove: Self.isOptionPressed)
            }
            .onEnded { _ in
                if panStart != nil {
                    editor.endCanvasGesture(.pan)
                    panStart = nil
                }
                editor.endDrag()
                isFocused = true
            }
    }

    /// Topic dragged on a read-only map: pans like the background.
    private func lockedPan(_ value: DragGesture.Value) {
        if panStart == nil { editor.showReadOnlyNotice() }
        editor.beginCanvasGesture(.pan)
        let start = panStart ?? editor.viewport
        if panStart == nil { panStart = start }
        var viewport = start
        viewport.pan(dx: value.translation.width, dy: value.translation.height)
        editor.viewport = viewport
    }
}

/// Rect with an inner rect cut out (even-odd), for `editingDragHandle`.
private struct FrameRing: Shape {
    var inset: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(rect.insetBy(dx: min(inset.width, rect.width / 2), dy: min(inset.height, rect.height / 2)))
        return path
    }
}
