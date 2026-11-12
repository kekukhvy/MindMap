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

    /// XMind-like selection ring color (fixed: the canvas is always light).
    static let selectionBlue = Color(hex: "#2E7CF6")

    private var appearance: NodeAppearance { info.appearance }
    private var color: Color { Color(hex: appearance.colorHex) }

    var body: some View {
        content
            .padding(.horizontal, appearance.paddingH * scale)
            .padding(.vertical, appearance.paddingV * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { background }
            .overlay { highlight }
    }

    private var font: Font {
        .system(size: appearance.fontSize * scale, weight: appearance.weight.fontWeight)
    }

    private var textColor: Color { Color(hex: appearance.textColorHex) }

    /// Stage 2 hook: attachment indicators (e.g. a notes "≡" icon in the
    /// branch color) go after the text here; the measurer must then add
    /// their width to the node size.
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
            shape.fill(Color(hex: appearance.fillHex ?? appearance.colorHex))
                .overlay { if appearance.border != nil { shape.stroke(color, style: strokeStyle(1.5)) } }
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
            outline.stroke(NodeView.selectionBlue, lineWidth: 2)
                .padding(-3 * scale)
        }
    }
}
