import SwiftUI

/// Interaction feedback above the map (not animated with layout):
/// relationship rubber band, sibling insertion indicator, control-point
/// handles of the selected relationship.
struct CanvasOverlays: View {
    let editor: EditorController
    let viewport: Viewport

    var body: some View {
        ZStack(alignment: .topLeading) {
            dragLine
            marquee
            rubberBand
            insertionIndicator
            controlHandles
            LabelEditorOverlay(editor: editor, viewport: viewport)
        }
    }

    // MARK: Live branch line of a dragged topic

    @ViewBuilder private var dragLine: some View {
        ForEach(editor.dragConnectors) { connector in
            let geometry = connector.geometry.transformed(by: viewport)
            ConnectorShape(geometry: geometry)
                .stroke(Color(hex: connector.colorHex), style: StrokeStyle(
                    lineWidth: geometry.startWidth, lineCap: .round, lineJoin: .round,
                    dash: ConnectorGeometry.dashPattern(geometry.dash, width: geometry.startWidth)
                ))
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
        }
    }

    // MARK: Rubber-band selection

    @ViewBuilder private var marquee: some View {
        if let band = editor.marquee {
            let rect = band.rect
            Rectangle()
                .fill(NodeView.selectionBlue.opacity(0.08))
                .overlay(Rectangle().stroke(NodeView.selectionBlue.opacity(0.8), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
        }
    }

    // MARK: Rubber band while choosing a relationship target

    @ViewBuilder private var rubberBand: some View {
        if let mode = editor.pickMode, mode.drawsRubberBand, let pointer = editor.pickPointer,
           let source = editor.scene.layout.frames[mode.sourceID] {
            let target = editor.pickHoverID.flatMap { editor.scene.layout.frames[$0] }
            let start = viewport.toScreen(CGPoint(x: source.midX, y: source.midY))
            let end = target.map { viewport.toScreen(CGPoint(x: $0.midX, y: $0.midY)) } ?? pointer
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
            .allowsHitTesting(false)
        }
    }

    // MARK: Drop before/after a sibling

    @ViewBuilder private var insertionIndicator: some View {
        if let drag = editor.drag, drag.placement != .child, let target = drag.targetID,
           let frame = editor.scene.layout.frames[target], let axis = drag.siblingAxis {
            let screen = viewport.toScreen(frame)
            let gap = (axis == .vertical ? LayoutSpacing().vertical : LayoutSpacing().rowGap) / 2 * viewport.scale
            let isBefore = drag.placement == .before
            let rect = axis == .vertical
                ? CGRect(x: screen.minX, y: (isBefore ? screen.minY - gap : screen.maxY + gap) - 1.5,
                         width: screen.width, height: 3)
                : CGRect(x: (isBefore ? screen.minX - gap : screen.maxX + gap) - 1.5, y: screen.minY,
                         width: 3, height: screen.height)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    // MARK: Curve handles of the selected relationship

    @ViewBuilder private var controlHandles: some View {
        // Not on a read-only map (WP15): the curve cannot be reshaped.
        if case let .relationship(id)? = editor.selectedItem, editor.canEdit, let relationship = editor.relationship(id),
           relationship.style.path == .curved, let path = editor.relationshipPath(id) {
            let screen = path.transformed(by: viewport)
            handleLine(from: screen.start, to: screen.control1)
            handleLine(from: screen.end, to: screen.control2)
            handle(at: screen.control1, id: id, isStart: true)
            handle(at: screen.control2, id: id, isStart: false)
        }
    }

    private func handleLine(from start: CGPoint, to end: CGPoint) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .allowsHitTesting(false)
    }

    private func handle(at point: CGPoint, id: UUID, isStart: Bool) -> some View {
        Circle()
            .fill(Color.canvasBackground)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 12, height: 12)
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasView.space))
                    .onChanged { value in
                        editor.updateControlDrag(id, isStart: isStart, translation: value.translation)
                    }
                    .onEnded { _ in editor.endControlDrag() }
            )
            .accessibilityLabel(isStart ? "Start curve handle" : "End curve handle")
    }
}

/// Banner shown while choosing a target topic.
struct PickBanner: View {
    let editor: EditorController

    var body: some View {
        if let mode = editor.pickMode {
            HStack(spacing: 10) {
                Text(mode.prompt).font(.callout)
                Button("Cancel") { editor.cancelPick() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
        }
    }
}

/// Banner while taps toggle the selection: editing a boundary's members
/// (Done stores them), or the iPad Select mode.
struct SelectionBanner: View {
    @Bindable var editor: EditorController

    var body: some View {
        if editor.boundaryMemberEditing != nil {
            HStack(spacing: 10) {
                Text(editor.memberEditPrompt).font(.callout)
                Button("Cancel") { editor.finishEditBoundaryMembers(commit: false) }
                    .buttonStyle(.borderless)
                Button("Done") { editor.finishEditBoundaryMembers(commit: true) }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
        } else if editor.isSelectMode {
            HStack(spacing: 10) {
                Text(editor.selectedIDs.isEmpty ? "Tap topics or drag an area to select"
                     : "\(editor.selectedIDs.count) selected").font(.callout)
                Button("Done") { editor.isSelectMode = false }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
        }
    }
}

/// Floating "Back" pill while topic-link jumps can be retraced (⌘[).
struct BackPill: View {
    let editor: EditorController

    var body: some View {
        if let target = editor.backTargetID {
            let full = LinkCandidate.displayText(editor.model.map.node(withID: target)?.text ?? "")
            let text = full.count > 32 ? String(full.prefix(31)) + "…" : full
            Button { editor.goBack() } label: {
                Label("Back to “\(text)”", systemImage: "chevron.backward")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Return to the previous topic (⌘[)")
            .padding(.bottom, 16)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
