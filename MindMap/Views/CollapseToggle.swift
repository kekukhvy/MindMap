import SwiftUI

/// MindManager-style +/− control on the edge of a topic where its branch
/// lines leave: "−" collapses, "+N" (hidden topic count) expands. Placed by
/// the canvas as a sibling of the topic, so clicking it never starts a drag
/// or changes the selection. One undo step per click.
struct CollapseToggle: View {
    let info: MapScene.NodeInfo
    /// Topic frame on screen.
    let frame: CGRect
    let scale: CGFloat
    let onToggle: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    private var color: Color { Color(hex: info.appearance.colorHex) }
    private var size: CGFloat { max(16 * scale, 12) }
    private var gap: CGFloat { 4 * scale }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: alignment) { button.padding(padding, gap).fixedSize() }
            .position(anchor)
    }

    private var button: some View {
        Group {
            if info.isCollapsed {
                Text(info.hiddenCount > 0 ? "+\(info.hiddenCount)" : "+")
                    .font(.system(size: max(10 * scale, 8), weight: .semibold))
                    .padding(.horizontal, 4 * scale)
            } else {
                Image(systemName: "minus")
                    .font(.system(size: max(8 * scale, 7), weight: .bold))
            }
        }
        .foregroundStyle(color)
        .frame(minWidth: size, minHeight: size)
        .background(Capsule().fill(Color.canvasBackground))
        .overlay(Capsule().stroke(color, lineWidth: max(1.5 * scale, 1)))
        .contentShape(Capsule().inset(by: -3))
        .onTapGesture(perform: onToggle)
        .onHover(perform: onHover)
        .help(info.isCollapsed ? "Expand (\(info.hiddenCount) hidden topics)" : "Collapse")
        .accessibilityLabel(info.isCollapsed ? "Expand, \(info.hiddenCount) hidden topics" : "Collapse")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("collapseToggle")
    }

    private var anchor: CGPoint {
        switch info.badgeEdge {
        case .leading: return CGPoint(x: frame.minX, y: frame.midY)
        case .trailing: return CGPoint(x: frame.maxX, y: frame.midY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.maxY)
        }
    }

    private var alignment: Alignment {
        switch info.badgeEdge {
        case .leading: return .trailing
        case .trailing: return .leading
        case .bottom: return .top
        }
    }

    private var padding: Edge.Set {
        switch info.badgeEdge {
        case .leading: return .trailing
        case .trailing: return .leading
        case .bottom: return .top
        }
    }
}
