import SwiftUI

/// Relationships (cross-links) above topics: animatable lines, arrowheads
/// and labels; tap selects, double-click edits the label, context menu styles.
struct RelationshipsLayer: View {
    let editor: EditorController
    let viewport: Viewport

    static let defaultColorHex = "#6B7785"

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(editor.model.map.relationships) { relationship in
                if let path = editor.relationshipPath(relationship.id) {
                    RelationshipView(editor: editor, relationship: relationship,
                                     geometry: path.transformed(by: viewport), scale: viewport.scale,
                                     isSelected: editor.selectedItem == .relationship(relationship.id))
                }
            }
        }
    }
}

private struct RelationshipView: View {
    let editor: EditorController
    let relationship: Relationship
    let geometry: RelationshipPath
    let scale: CGFloat
    let isSelected: Bool

    private var style: RelationshipStyle { relationship.style }
    private var color: Color { Color(hex: style.colorHex ?? RelationshipsLayer.defaultColorHex) }
    private var width: CGFloat { CGFloat(style.width) * scale }
    private var item: CanvasItem { .relationship(relationship.id) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isSelected {
                RelationshipShape(geometry: geometry, pathStyle: style.path, part: .line)
                    .stroke(Color.accentColor.opacity(0.3), style: StrokeStyle(lineWidth: width + 6, lineCap: .round,
                                                                               lineJoin: .round))
            }
            RelationshipShape(geometry: geometry, pathStyle: style.path, part: .line)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                                                  dash: ConnectorGeometry.dashPattern(style.dash, width: width)))
            head(.startHead(style.startArrow, length: headLength), style.startArrow)
            head(.endHead(style.endArrow, length: headLength), style.endArrow)
        }
        .contentShape(hitShape)
        #if os(iOS)
        .contentShape(.contextMenuPreview, hitShape)
        #endif
        .modifier(ItemGestures(editor: editor, item: item))
        .overlay(alignment: .topLeading) { label }
    }

    private var hitShape: RelationshipHitShape {
        RelationshipHitShape(geometry: geometry, pathStyle: style.path, tolerance: EditorController.hitTolerance)
    }

    private var headLength: CGFloat { max(8 * scale, width * 4) }

    @ViewBuilder
    private func head(_ part: RelationshipShape.Part, _ kind: ArrowHead) -> some View {
        let shape = RelationshipShape(geometry: geometry, pathStyle: style.path, part: part)
        switch kind {
        case .none: EmptyView()
        case .arrow: shape.stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        case .filledArrow, .dot, .diamond: shape.fill(color)
        }
    }

    @ViewBuilder private var label: some View {
        if let text = relationship.label, !text.isEmpty {
            Text(text)
                .font(.system(size: 12 * scale))
                .foregroundStyle(color)
                .padding(.horizontal, 4 * scale)
                .padding(.vertical, 2 * scale)
                .background(RoundedRectangle(cornerRadius: 4 * scale).fill(Color.canvasBackground))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4 * scale).stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .fixedSize()
                .contentShape(Rectangle())
                .modifier(ItemGestures(editor: editor, item: item))
                .position(geometry.labelPoint)
        }
    }
}

/// Tap = select, double-click = edit label, context menu with the item's
/// menu (selecting it first). Shared by relationships and boundaries.
struct ItemGestures: ViewModifier {
    let editor: EditorController
    let item: CanvasItem

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { editor.beginLabelEdit(item) }
            .simultaneousGesture(TapGesture().onEnded {
                if editor.pickMode != nil { editor.cancelPick() }
                editor.selectItem(item)
            })
            .contextMenu {
                CanvasItemMenu(editor: editor, item: item)
                    .onAppear { if editor.selectedItem != item { editor.selectItem(item) } }
            }
    }
}
