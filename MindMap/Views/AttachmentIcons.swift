import SwiftUI

/// What a topic shows of one attachment (never its content).
struct AttachmentSummary: Equatable, Identifiable {
    var id: UUID
    var kind: AttachmentKind
    var title: String
    /// Locked note (WP12): the icon gets a lock badge.
    var isLocked = false

    init(_ attachment: Attachment) {
        id = attachment.id
        kind = attachment.kind
        title = attachment.title
        isLocked = attachment.isLocked
    }
}

extension AttachmentKind {
    /// XMind-like indicators: "≡" lines for notes, scribble, paperclip.
    var systemImage: String {
        switch self {
        case .markdown: return "text.alignleft"
        case .drawing: return "scribble"
        case .file: return "paperclip"
        }
    }

    var displayName: String {
        switch self {
        case .markdown: return "Note"
        case .drawing: return "Handwritten Note"
        case .file: return "File"
        }
    }
}

/// Pure metrics of the icon row at a topic's trailing edge (map points at
/// zoom 1, scaled by the view). Used by `NodeMeasurer` so the layout
/// reserves the icons' width.
enum AttachmentIconRow {
    enum Item: Equatable, Identifiable {
        /// Opens `attachmentID` (the first of that kind when collapsed).
        case icon(AttachmentKind, attachmentID: UUID)
        /// "N" badge (more than `maxIcons` attachments): menu of all.
        case count(Int)

        var id: String {
            switch self {
            case let .icon(_, id): return id.uuidString
            case .count: return "count"
            }
        }
    }

    static let maxIcons = 3

    /// Up to 3 attachments: one icon each. More: one icon per kind + count badge.
    static func items(_ attachments: [AttachmentSummary]) -> [Item] {
        guard attachments.count > maxIcons else { return attachments.map { .icon($0.kind, attachmentID: $0.id) } }
        var seen = Set<AttachmentKind>()
        let icons: [Item] = attachments.compactMap { seen.insert($0.kind).inserted ? .icon($0.kind, attachmentID: $0.id) : nil }
        return icons + [.count(attachments.count)]
    }

    static func iconSize(fontSize: CGFloat) -> CGFloat { max(11, (fontSize * 0.95).rounded()) }
    static func spacing(fontSize: CGFloat) -> CGFloat { max(2, (fontSize * 0.25).rounded()) }
    /// Gap between the text and the first icon.
    static func leadingGap(fontSize: CGFloat) -> CGFloat { max(4, (fontSize * 0.4).rounded()) }

    static func width(of item: Item, fontSize: CGFloat) -> CGFloat {
        let icon = iconSize(fontSize: fontSize)
        switch item {
        case .icon: return icon
        case let .count(n): return (icon * (n >= 10 ? 1.7 : 1.3)).rounded()
        }
    }

    /// Distance between the centers of neighbouring icons.
    static func stride(fontSize: CGFloat) -> CGFloat { iconSize(fontSize: fontSize) + spacing(fontSize: fontSize) }

    /// Whether the icons can be reordered by dragging (one icon per
    /// attachment, at least two).
    static func isReorderable(_ attachments: [AttachmentSummary]) -> Bool {
        attachments.count >= 2 && attachments.count <= maxIcons
    }

    /// Slot an icon dragged by `translation` (view points; `stride` at the
    /// current zoom) from `slot` lands in, clamped to the row.
    static func targetSlot(from slot: Int, translation: CGFloat, stride: CGFloat, count: Int) -> Int {
        guard stride > 0, count > 0 else { return slot }
        return min(max(slot + Int((translation / stride).rounded()), 0), count - 1)
    }

    /// Total width added to the topic (0 without attachments).
    static func width(_ items: [Item], fontSize: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let content = items.reduce(0) { $0 + width(of: $1, fontSize: fontSize) }
        return leadingGap(fontSize: fontSize) + content + spacing(fontSize: fontSize) * CGFloat(items.count - 1)
    }
}

/// The compact icon row drawn inside a topic after its text.
struct AttachmentIconsView: View {
    let attachments: [AttachmentSummary]
    let fontSize: CGFloat
    let scale: CGFloat
    let color: Color
    let onOpen: (UUID) -> Void
    /// Icon dragged to another slot (drag sideways; one icon per attachment).
    var onMove: (UUID, Int) -> Void = { _, _ in }
    @State private var dragged: (id: UUID, offset: CGFloat)?

    var body: some View {
        let items = AttachmentIconRow.items(attachments)
        let reorderable = AttachmentIconRow.isReorderable(attachments)
        HStack(spacing: AttachmentIconRow.spacing(fontSize: fontSize) * scale) {
            ForEach(Array(items.enumerated()), id: \.element.id) { slot, item in
                switch item {
                case let .icon(kind, id):
                    Button { onOpen(id) } label: {
                        icon(kind, locked: attachments.contains { $0.id == id && $0.isLocked })
                    }
                    .buttonStyle(.plain)
                    .offset(x: dragged?.id == id ? dragged!.offset : 0)
                    .zIndex(dragged?.id == id ? 1 : 0)
                    .gesture(reorderable ? reorderDrag(id, slot: slot, count: items.count) : nil)
                    .help(tooltip(kind, id: id, collapsed: attachments.count > AttachmentIconRow.maxIcons))
                    .accessibilityLabel("Open \(kind.displayName)")
                case let .count(n):
                    Menu {
                        ForEach(attachments) { attachment in
                            Button(attachment.title.isEmpty ? attachment.kind.displayName : attachment.title,
                                   systemImage: attachment.kind.systemImage) { onOpen(attachment.id) }
                        }
                    } label: {
                        Text("\(n)")
                            .font(.system(size: fontSize * 0.7 * scale, weight: .semibold))
                            .foregroundStyle(color)
                            .frame(width: AttachmentIconRow.width(of: item, fontSize: fontSize) * scale,
                                   height: AttachmentIconRow.iconSize(fontSize: fontSize) * scale)
                            .background(Capsule().stroke(color.opacity(0.8), lineWidth: max(0.75, scale)))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(n) attachments")
                }
            }
        }
        .padding(.leading, AttachmentIconRow.leadingGap(fontSize: fontSize) * scale)
    }

    /// Sideways drag of an icon: follows the pointer within the row, drops
    /// into the nearest slot (one "Move Attachment" undo step). Wins over
    /// the topic's own drag when it starts on an icon.
    private func reorderDrag(_ id: UUID, slot: Int, count: Int) -> some Gesture {
        let stride = AttachmentIconRow.stride(fontSize: fontSize) * scale
        return DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                let limit = (CGFloat(-slot) - 0.4) * stride ... (CGFloat(count - 1 - slot) + 0.4) * stride
                dragged = (id, min(max(value.translation.width, limit.lowerBound), limit.upperBound))
            }
            .onEnded { value in
                dragged = nil
                let target = AttachmentIconRow.targetSlot(from: slot, translation: value.translation.width,
                                                          stride: stride, count: count)
                if target != slot { onMove(id, target) }
            }
    }

    /// macOS hover text: the file name / note title; when the row is
    /// collapsed (one icon per kind) all titles of that kind.
    private func tooltip(_ kind: AttachmentKind, id: UUID, collapsed: Bool) -> String {
        let titles = (collapsed ? attachments.filter { $0.kind == kind } : attachments.filter { $0.id == id })
            .map { ($0.title.isEmpty ? kind.displayName : $0.title) + ($0.isLocked ? " (locked)" : "") }
        return titles.isEmpty ? kind.displayName : titles.joined(separator: "\n")
    }

    private func icon(_ kind: AttachmentKind, locked: Bool) -> some View {
        let size = AttachmentIconRow.iconSize(fontSize: fontSize) * scale
        return Image(systemName: kind.systemImage)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .frame(width: size * 0.82, height: size * 0.82)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if locked { LockBadge(size: size * 0.55, color: color) }
            }
            .contentShape(Rectangle())
            .accessibilityValue(locked ? "Locked" : "")
    }
}

/// Small padlock on the icon of a locked note.
struct LockBadge: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        Image(systemName: "lock.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .padding(size * 0.12)
            .frame(width: size, height: size)
            .background(Circle().fill(.white))
            .offset(x: size * 0.3, y: size * 0.25)
    }
}
