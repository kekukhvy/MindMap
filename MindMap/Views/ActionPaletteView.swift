import SwiftUI

/// iPad floating action palette (XMind-like dark capsule) placed above /
/// below the selected topic(s), or at a point for the Insert palette. It is
/// laid out from the viewport on every render, so it follows pan / zoom; it
/// is hidden while panning, zooming, dragging or editing (`ActionPaletteState`).
struct ActionPaletteLayer: View {
    @Bindable var editor: EditorController
    let viewport: Viewport
    @State private var size: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let mode = editor.visiblePalette, let anchor = anchor(for: mode) {
                let placement = PalettePlacement.place(anchor: anchor, size: size, in: editor.viewSize,
                                                       topInset: topInset, belowClearance: belowClearance(mode),
                                                       obstacles: obstacles)
                ActionPaletteView(editor: editor, items: editor.paletteItems,
                                  header: editor.isMultiSelection && mode == .selection
                                      ? "\(editor.selectedIDs.count) selected" : nil,
                                  compact: isCompact)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .position(placement?.center ?? CGPoint(x: -1000, y: -1000))
                    .opacity(size == .zero || placement == nil ? 0 : 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.16), value: editor.visiblePalette)
    }

    /// Icons only when the labelled palette would not fit (narrow windows).
    private var isCompact: Bool {
        CGFloat(editor.paletteItems.count) * ActionPaletteView.itemWidth + 60 > editor.viewSize.width - 24
    }

    /// Topics the palette should not cover (all but the selection; text
    /// matters, so the central topic counts double).
    private var obstacles: [CGRect] {
        let scene = editor.scene
        return scene.order.compactMap { id -> [CGRect]? in
            guard !editor.isSelected(id), let frame = editor.screenFrame(of: id) else { return nil }
            return id == editor.model.root.id ? [frame, frame] : [frame]
        }.flatMap { $0 }
    }

    /// Room for the Select-mode / pick banners at the top.
    private var topInset: CGFloat {
        editor.isSelectMode || editor.pickMode != nil || editor.boundaryMemberEditing != nil ? 52 : 0
    }

    private func anchor(for mode: ActionPaletteState.Mode) -> CGRect? {
        switch mode {
        case let .insert(point):
            return CGRect(origin: point, size: .zero)
        case .selection:
            guard let primary = editor.selectedID.flatMap(editor.screenFrame(of:)) else { return nil }
            let ring = 6 * viewport.scale
            let frames = editor.selection.compactMap(editor.screenFrame(of:))
            return PalettePlacement.anchor(primary: primary, selection: frames, container: editor.viewSize)
                .insetBy(dx: -ring, dy: -ring)
        }
    }

    /// A tree-down topic shows its toggle / "+" below: keep the palette clear.
    private func belowClearance(_ mode: ActionPaletteState.Mode) -> CGFloat {
        guard mode == .selection, let id = editor.selectedID, let info = editor.scene.nodes[id],
              info.badgeEdge == .bottom else { return 0 }
        return AddChildHandle.toggleExtent(isShown: info.hasChildren, edge: .bottom, isCollapsed: info.isCollapsed,
                                           hiddenCount: info.hiddenCount, scale: viewport.scale)
            + AddChildHandle.gap + AddChildHandle.diameter
    }
}

/// The capsule itself: one button per `PaletteItem`; "More" opens the full
/// topic context menu (layout, format, collapse, boundary, relationship,
/// attachments, handwriting…).
struct ActionPaletteView: View {
    let editor: EditorController
    let items: [PaletteItem]
    var header: String?
    var compact = false

    static let itemWidth: CGFloat = 52
    static let background = Color(white: 0.15)

    var body: some View {
        HStack(spacing: 0) {
            if let header {
                Text(header)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .fixedSize()
                divider
            }
            ForEach(items) { item in
                if item.action == .more { divider }
                button(item)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(Self.background.opacity(0.97)))
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("actionPalette")
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 26).padding(.horizontal, 3)
    }

    @ViewBuilder private func button(_ item: PaletteItem) -> some View {
        if item.action == .more, let id = editor.selectedID {
            Menu {
                NodeContextMenu(editor: editor, id: id)
            } label: {
                label(item)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(PaletteButtonStyle())
            .accessibilityIdentifier("palette.more")
        } else {
            Button { editor.performPaletteAction(item.action) } label: { label(item) }
                .buttonStyle(PaletteButtonStyle())
                .disabled(!item.isEnabled)
                .accessibilityIdentifier("palette.\(item.action.rawValue)")
        }
    }

    private func label(_ item: PaletteItem) -> some View {
        let tint: Color = item.isDestructive ? Color(red: 1, green: 0.48, blue: 0.45) : .white
        return VStack(spacing: 3) {
            Image(systemName: item.systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(height: 20)
            if !compact {
                Text(item.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(item.isEnabled ? tint : .white.opacity(0.32))
        .frame(minWidth: compact ? 40 : Self.itemWidth, minHeight: compact ? 40 : 46)
        .contentShape(Rectangle())
        .accessibilityLabel(item.title)
    }
}

private struct PaletteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(configuration.isPressed ? 0.16 : 0)))
    }
}

/// "+" on the child side of the selected / Pencil-hovered topic: tap adds
/// a child and starts naming it. Fixed screen size (touch target 44 pt).
struct AddChildHandleView: View {
    let center: CGPoint
    let onTap: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: AddChildHandle.diameter, height: AddChildHandle.diameter)
            .background(Circle().fill(NodeView.selectionBlue))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .frame(width: AddChildHandle.hitDiameter, height: AddChildHandle.hitDiameter)
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
            .onHover(perform: onHover)
            .position(center)
            .accessibilityLabel("Add Child Topic")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("addChildHandle")
    }
}
