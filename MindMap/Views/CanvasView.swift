import SwiftUI

/// The mind-map canvas: pan/zoom, branch lines, topics, gestures, keyboard.
struct CanvasView: View {
    @Bindable var editor: EditorController
    @FocusState private var isFocused: Bool
    @State private var pinchStart: Viewport?
    @State private var panStart: Viewport?
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
                    ConnectorsLayer(connectors: scene.connectors, viewport: viewport)
                    ForEach(scene.order, id: \.self) { id in
                        node(id, scene: scene, viewport: viewport)
                    }
                    ForEach(scene.order, id: \.self) { id in
                        collapseToggle(id, scene: scene, viewport: viewport)
                    }
                    editingDragHandle(scene: scene, viewport: viewport)
                    RelationshipsLayer(editor: editor, viewport: viewport)
                }
                .animation(.snappy(duration: 0.25), value: editor.model.map)
                CanvasOverlays(editor: editor, viewport: viewport)
            }
            .overlay(alignment: .top) { PickBanner(editor: editor) }
            .onContinuousHover(coordinateSpace: .named(CanvasView.space)) { phase in
                guard editor.pickMode != nil else { return }
                if case let .active(location) = phase { editor.pickPointer = location } else { editor.pickPointer = nil }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(.named(CanvasView.space))
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(magnify)
            .onAppear { editor.updateViewSize(proxy.size) }
            .onChange(of: proxy.size) { _, size in editor.updateViewSize(size) }
        }
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($isFocused)
        // Published only while the canvas (or its inline editor) has focus, so
        // plain-key menu shortcuts never steal keys from other text inputs.
        .focusedValue(\.mindMapCommandState, editor.commandState)
        .mindMapKeyboard(editor)
        .onAppear { isFocused = true }
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
                editor.cancelPick()
                editor.select(nil)
                isFocused = true
            })
            .gesture(pan)
            #if os(macOS)
            .contextMenu { CanvasBackgroundMenu(editor: editor) }
            #endif
            #if os(iOS)
            .background(TabKeyBridge {
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

    private var pan: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = panStart ?? editor.viewport
                if panStart == nil { panStart = start }
                var viewport = start
                viewport.pan(dx: value.translation.width, dy: value.translation.height)
                editor.viewport = viewport
            }
            .onEnded { _ in panStart = nil }
    }

    private static var isOptionPressed: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option) || ScrollWheelHandler.lastMouseModifiers.contains(.option)
        #else
        false
        #endif
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? editor.viewport
                if pinchStart == nil { pinchStart = start }
                var viewport = start
                viewport.zoom(to: start.scale * value.magnification, around: value.startLocation)
                editor.viewport = viewport
            }
            .onEnded { _ in pinchStart = nil }
    }

    // MARK: Topics

    @ViewBuilder
    private func node(_ id: UUID, scene: MapScene, viewport: Viewport) -> some View {
        if let info = scene.nodes[id], let frame = scene.layout.frames[id] {
            let screen = viewport.toScreen(frame)
            let drag = editor.drag?.id == id ? editor.drag : nil
            NodeView(info: info, scale: viewport.scale, isSelected: editor.selectedID == id,
                     isDropTarget: editor.drag?.parentTargetID == id || editor.pickHoverID == id,
                     editor: editor.editingID == id ? editor : nil, nodeID: id)
                .frame(width: screen.width, height: screen.height)
                .contentShape(Rectangle())
                .opacity(drag == nil ? 1 : 0.75)
                .offset(drag?.translation ?? .zero)
                .zIndex(drag == nil ? 0 : 1)
                .position(x: screen.midX, y: screen.midY)
                .gesture(reparentDrag(id), including: id == editor.model.root.id ? .subviews : .all)
                // Double-click / double-tap = new child (being named); rename via
                // the context menu, Space, F2 or typing.
                .onTapGesture(count: 2) {
                    guard editor.pickMode == nil, editor.editingID != id else { return }
                    editor.select(id)
                    editor.addChild()
                }
                .onHover { inside in editor.setHovered(id, inside) }
                .simultaneousGesture(TapGesture().onEnded {
                    if editor.completePick(id) { return }
                    if editor.editingID != id { editor.select(id) }
                    if editor.editingID == nil { isFocused = true }
                })
                #if os(iOS)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                    if editor.selectedID != id, editor.editingID != id { editor.select(id) }
                })
                #endif
                .contextMenu {
                    NodeContextMenu(editor: editor, id: id)
                }
        }
    }

    @ViewBuilder
    private func collapseToggle(_ id: UUID, scene: MapScene, viewport: Viewport) -> some View {
        if let info = scene.nodes[id], info.hasChildren, editor.drag?.id != id,
           info.isCollapsed || editor.selectedID == id || editor.hoveredID == id,
           let frame = scene.layout.frames[id] {
            CollapseToggle(info: info, frame: viewport.toScreen(frame), scale: viewport.scale,
                           onToggle: { editor.toggleCollapse(id) },
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
                editor.updateDrag(id, translation: value.translation, location: value.location,
                                  freeMove: Self.isOptionPressed)
            }
            .onEnded { _ in
                editor.endDrag()
                isFocused = true
            }
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
