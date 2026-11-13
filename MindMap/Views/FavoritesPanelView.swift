import SwiftUI

/// The virtual "Favorites (N)" card on the canvas: same look as the Tasks
/// panel, derived live from the favorite topics. Header drag = move
/// (undoable, saved); chevron = collapse; a row click selects the topic and
/// scrolls to it.
struct FavoritesPanelView: View {
    let editor: EditorController
    let panel: FavoritesPanelContent
    let viewport: Viewport

    private var scale: CGFloat { viewport.scale }
    private var ink: Color { Color(hex: TasksPanelView.inkHex) }

    var body: some View {
        let drag = editor.favoritesPanelDrag ?? .zero
        let screen = viewport.toScreen(panel.frame).offsetBy(dx: drag.width, dy: drag.height)
        let shape = RoundedRectangle(cornerRadius: TaskPanelLayout.cornerRadius * scale, style: .continuous)
        VStack(spacing: 0) {
            header
            if !panel.isCollapsed {
                if panel.scrollsRows {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) { rows }
                    }
                    .frame(height: CGFloat(TaskPanelLayout.maxRows) * TaskPanelLayout.rowHeight * scale)
                } else {
                    rows
                }
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .top)
        .background(shape.fill(Color.white))
        .clipShape(shape)
        .overlay(shape.stroke(Color(hex: TasksPanelView.borderHex), lineWidth: max(1, 1.25 * scale)))
        .shadow(color: .black.opacity(0.10), radius: 8 * scale, y: 2 * scale)
        .position(x: screen.midX, y: screen.midY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Favorites panel")
    }

    private var rows: some View {
        ForEach(panel.entries) { entry in
            row(entry)
        }
    }

    private func row(_ entry: FavoriteEntry) -> some View {
        HStack(spacing: 8 * scale) {
            Circle()
                .fill(Color(hex: editor.scene.colors[entry.id] ?? ColorTheme.rootColorHex))
                .frame(width: 7 * scale, height: 7 * scale)
            Text(entry.text)
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: TaskPanelLayout.rowHeight * scale)
        .background(editor.selectedID == entry.id ? Color(hex: "#2E7CF6").opacity(0.10) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { editor.showFavorite(entry.id) }
        .contextMenu {
            Button("Show Topic", systemImage: "scope") { editor.showFavorite(entry.id) }
            Button("Remove from Favorites", systemImage: "star.slash") { editor.removeFavorite(entry.id) }
                .disabled(editor.isReadOnly)
        }
        .help(entry.text)
    }

    private var header: some View {
        HStack(spacing: 6 * scale) {
            Button { editor.toggleFavoritesPanelCollapsed() } label: {
                Image(systemName: panel.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(ink.opacity(0.6))
                    .frame(width: 18 * scale, height: 18 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(panel.isCollapsed ? "Expand" : "Collapse")
            Image(systemName: "star.fill")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(Color(hex: "#F5A623"))
            Text("Favorites (\(panel.entries.count))")
                .font(.system(size: 14.5 * scale, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Button("Reset Position", systemImage: "arrow.uturn.backward.circle") {
                    editor.resetFavoritesPanelPosition()
                }
                .disabled(panel.isAutoPositioned || editor.isReadOnly)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13 * scale, weight: .bold))
                    .foregroundStyle(ink.opacity(0.6))
                    .frame(width: 22 * scale, height: 18 * scale)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: TaskPanelLayout.headerHeight * scale)
        .background(Color(hex: TasksPanelView.headerFillHex))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(CanvasView.space))
                .onChanged { editor.updateFavoritesPanelDrag($0.translation) }
                .onEnded { _ in editor.endFavoritesPanelDrag() }
        )
        .help(editor.isReadOnly ? "" : "Drag to move the Favorites panel")
    }
}
