import SwiftUI

/// Visual of one topic at the current zoom (fonts scaled, not bitmaps).
/// The frame is set by the canvas from the measured layout size.
struct NodeView: View {
    let info: MapScene.NodeInfo
    let scale: CGFloat
    let isSelected: Bool
    let isDropTarget: Bool
    /// Inline editor shown instead of the text (nil = not editing).
    let editor: EditorController?
    let nodeID: UUID
    var onBadgeTap: () -> Void = {}

    private var appearance: NodeAppearance { info.appearance }
    private var color: Color { Color(hex: appearance.colorHex) }

    var body: some View {
        content
            .padding(.horizontal, appearance.paddingH * scale)
            .padding(.vertical, appearance.paddingV * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { background }
            .overlay { highlight }
            .overlay(alignment: badgeAlignment) { badgeAnchor }
    }

    private var font: Font {
        .system(size: appearance.fontSize * scale, weight: appearance.weight.fontWeight)
    }

    private var textColor: Color {
        guard appearance.fill == .solid else { return .primary }
        return appearance.usesDarkTextOnFill ? Color(white: 0.12) : .white
    }

    @ViewBuilder private var content: some View {
        if let editor {
            NodeEditorField(editor: editor, nodeID: nodeID, font: font, textColor: textColor)
        } else {
            Text(info.text)
                .font(font)
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
                .lineLimit(NodeMeasurer.maxLines)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var shape: AnyShape {
        switch appearance.shape {
        case .roundedRect: return AnyShape(RoundedRectangle(cornerRadius: appearance.cornerRadius * scale,
                                                            style: .continuous))
        case .capsule: return AnyShape(Capsule())
        case .rectangle, .underline, .plainText: return AnyShape(Rectangle())
        }
    }

    private func strokeStyle(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width * scale, lineCap: .round,
                    dash: appearance.border == .dashed ? [5 * scale, 3 * scale] : [])
    }

    @ViewBuilder private var background: some View {
        switch appearance.fill {
        case .solid:
            shape.fill(color)
                .overlay { if appearance.border != nil { shape.stroke(color.opacity(0.55), style: strokeStyle(2)) } }
        case .tint:
            shape.fill(color.opacity(0.14))
                .overlay { shape.stroke(color, style: strokeStyle(1.5)) }
        case .none:
            if appearance.shape == .underline {
                GeometryReader { proxy in
                    Path { path in
                        let y = proxy.size.height - NodeAppearance.underlineWidth / 2 * scale
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    .stroke(color, style: strokeStyle(NodeAppearance.underlineWidth))
                }
            } else if appearance.border != nil {
                shape.stroke(color, style: strokeStyle(1.5))
            }
        }
    }

    @ViewBuilder private var highlight: some View {
        let outline = RoundedRectangle(cornerRadius: (appearance.cornerRadius + 3) * scale, style: .continuous)
        if isDropTarget {
            outline.fill(Color.accentColor.opacity(0.15))
                .overlay { outline.stroke(Color.accentColor, lineWidth: 3) }
                .padding(-5 * scale)
        } else if isSelected {
            outline.stroke(Color.accentColor, lineWidth: 2)
                .padding(-4 * scale)
        }
    }

    private var badgeAlignment: Alignment {
        switch info.badgeEdge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .bottom: return .bottom
        }
    }

    /// Zero-size anchor on the node edge; the badge hangs outside it.
    @ViewBuilder private var badgeAnchor: some View {
        let gap = 5 * scale
        switch info.badgeEdge {
        case .leading:
            Color.clear.frame(width: 0).overlay(alignment: .trailing) { badge.padding(.trailing, gap).fixedSize() }
        case .trailing:
            Color.clear.frame(width: 0).overlay(alignment: .leading) { badge.padding(.leading, gap).fixedSize() }
        case .bottom:
            Color.clear.frame(height: 0).overlay(alignment: .top) { badge.padding(.top, gap).fixedSize() }
        }
    }

    @ViewBuilder private var badge: some View {
        if info.hiddenCount > 0 {
            Text("\(info.hiddenCount)")
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 5 * scale)
                .frame(minWidth: 18 * scale, minHeight: 18 * scale)
                .background(Capsule().fill(Color.canvasBackground))
                .overlay(Capsule().stroke(color, lineWidth: 1.5 * scale))
                .fixedSize()
                .contentShape(Capsule())
                .onTapGesture(perform: onBadgeTap)
                .accessibilityLabel("\(info.hiddenCount) hidden topics")
        }
    }
}
