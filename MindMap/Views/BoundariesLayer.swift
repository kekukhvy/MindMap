import SwiftUI

/// Boundaries behind topics: dashed outline, light hatched translucent
/// fill in the boundary/branch color, optional label tab. The outline band
/// and the tab are hit areas (tap selects, double-click edits the label).
struct BoundariesLayer: View {
    let editor: EditorController
    let viewport: Viewport

    var body: some View {
        let scene = editor.scene
        ZStack(alignment: .topLeading) {
            ForEach(editor.model.map.boundaries) { boundary in
                if let rect = scene.layout.boundaries[boundary.id] {
                    BoundaryView(editor: editor, boundary: boundary, rect: viewport.toScreen(rect),
                                 color: Color(hex: editor.boundaryColorHex(boundary)), scale: viewport.scale,
                                 isSelected: editor.selectedItem == .boundary(boundary.id))
                }
            }
        }
    }
}

private struct BoundaryView: View {
    let editor: EditorController
    let boundary: Boundary
    let rect: CGRect
    let color: Color
    let scale: CGFloat
    let isSelected: Bool

    private var cornerRadius: CGFloat { 12 * scale }

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let hit = BoundaryHitShape(cornerRadius: cornerRadius, band: EditorController.hitTolerance,
                                   tab: boundary.hasLabel ? tabSize : nil)
        ZStack(alignment: .topLeading) {
            outline.fill(color.opacity(0.06))
            HatchShape(spacing: 9 * scale).stroke(color.opacity(0.16), lineWidth: max(0.75, scale))
                .clipShape(outline)
            outline.stroke(color.opacity(isSelected ? 1 : 0.8),
                           style: StrokeStyle(lineWidth: (isSelected ? 2.5 : 1.5) * scale,
                                              dash: [6 * scale, 4 * scale]))
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius + 3 * scale, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .padding(-3 * scale)
            }
            labelTab
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(hit)
        #if os(iOS)
        .contentShape(.contextMenuPreview, hit)
        #endif
        .modifier(ItemGestures(editor: editor, item: .boundary(boundary.id)))
        .position(x: rect.midX, y: rect.midY)
    }

    private var tabSize: CGSize {
        CGSize(width: min(CanvasHitTester.boundaryTabWidth * scale, rect.width),
               height: LayoutSpacing().boundaryLabelHeight * scale)
    }

    @ViewBuilder private var labelTab: some View {
        if let label = boundary.label, !label.isEmpty {
            Text(label)
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6 * scale)
                .padding(.vertical, 2 * scale)
                .background(RoundedRectangle(cornerRadius: 4 * scale).fill(color))
                .fixedSize()
                .padding(.leading, 8 * scale)
                .padding(.top, 3 * scale)
        }
    }
}

/// Diagonal hatch lines filling the rect.
struct HatchShape: Shape {
    var spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = max(spacing, 2)
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return path
    }
}

/// Outline band (± `band`) of a rounded rect plus an optional top-left tab.
struct BoundaryHitShape: Shape {
    var cornerRadius: CGFloat
    var band: CGFloat
    var tab: CGSize?

    func path(in rect: CGRect) -> Path {
        let outline = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        var path = outline.strokedPath(StrokeStyle(lineWidth: band * 2))
        if let tab {
            path.addRect(CGRect(x: rect.minX + band, y: rect.minY + band,
                                width: max(tab.width - band, 0), height: max(tab.height - band, 0)))
        }
        return path
    }
}
