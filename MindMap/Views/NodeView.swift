import SwiftUI

/// Visual of one topic at the current zoom (fonts scaled, not bitmaps).
/// The frame is set by the canvas from the measured layout size.
struct NodeView: View {
    let info: MapScene.NodeInfo
    let scale: CGFloat
    let isSelected: Bool
    /// The keyboard-focus topic of a (multi-)selection: stronger ring.
    var isPrimarySelection = true
    /// Apple Pencil / pointer hover (iPad): faint ring.
    var isHovered = false
    let isDropTarget: Bool
    /// Inline editor shown instead of the text (nil = not editing).
    let editor: EditorController?
    let nodeID: UUID
    /// Tap on an attachment icon.
    var onOpenAttachment: (UUID) -> Void = { _ in }
    /// Attachment icon dragged sideways to another slot of the icon row.
    var onMoveAttachment: (UUID, Int) -> Void = { _, _ in }
    /// Tap on the link icon (Go to).
    var onFollowLink: () -> Void = {}
    /// Tap on the task checkbox (toggle done).
    var onToggleTask: () -> Void = {}

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

    private var isDone: Bool { info.task?.isDone == true }

    /// Task checkbox, link icon, priority mark, text (or the inline editor),
    /// due chip, attachment icons; the measurer reserves their width
    /// (`TaskBadgeMetrics`, `LinkIconMetrics`, `AttachmentIconRow`).
    private var content: some View {
        HStack(spacing: 0) {
            if let task = info.task {
                TaskCheckboxView(isDone: task.isDone,
                                 size: TaskBadgeMetrics.checkboxSize(fontSize: appearance.fontSize) * scale,
                                 color: textColor, action: onToggleTask)
                    .padding(.trailing, TaskBadgeMetrics.gap(fontSize: appearance.fontSize) * scale)
            }
            if let link = info.link {
                LinkIconView(link: link, fontSize: appearance.fontSize, scale: scale, color: textColor,
                             onFollow: onFollowLink)
            }
            if let task = info.task, let priority = task.priority {
                PriorityMarkView(priority: priority, width: task.priorityWidth, fontSize: appearance.fontSize,
                                 scale: scale, dimmed: task.isDone)
                    .padding(.trailing, TaskBadgeMetrics.gap(fontSize: appearance.fontSize) * 0.5 * scale)
            }
            text
            if let task = info.task, let due = task.due {
                DueChipView(label: due, isDone: task.isDone, fontSize: appearance.fontSize, scale: scale,
                            textColor: textColor)
                    .padding(.leading, TaskBadgeMetrics.gap(fontSize: appearance.fontSize) * scale)
            }
            if !info.attachments.isEmpty {
                AttachmentIconsView(attachments: info.attachments, fontSize: appearance.fontSize, scale: scale,
                                    color: textColor.opacity(0.75), onOpen: onOpenAttachment,
                                    onMove: onMoveAttachment)
            }
        }
    }

    @ViewBuilder private var text: some View {
        if let editor {
            NodeEditorField(editor: editor, nodeID: nodeID, font: font, textColor: textColor)
        } else {
            Text(info.text)
                .font(font)
                .foregroundStyle(textColor.opacity(isDone ? 0.5 : 1))
                .strikethrough(isDone, color: textColor.opacity(0.5))
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
            outline.stroke(NodeView.selectionBlue.opacity(isPrimarySelection ? 1 : 0.7),
                           lineWidth: isPrimarySelection ? 2.5 : 1.5)
                .padding(-3 * scale)
        } else if isHovered {
            outline.fill(NodeView.selectionBlue.opacity(0.06))
                .overlay { outline.stroke(NodeView.selectionBlue.opacity(0.45), lineWidth: 1.5) }
                .padding(-3 * scale)
                .allowsHitTesting(false)
        }
    }
}
