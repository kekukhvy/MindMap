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
                if let outline = scene.layout.boundaries[boundary.id] {
                    BoundaryView(editor: editor, boundary: boundary, outline: outline,
                                 rect: viewport.toScreen(outline.bounds),
                                 color: Color(hex: editor.boundaryColorHex(boundary)), scale: viewport.scale,
                                 isSelected: editor.selectedItem == .boundary(boundary.id)
                                     || editor.boundaryMemberEditing == boundary.id)
                }
            }
        }
    }
}

private struct BoundaryView: View {
    let editor: EditorController
    let boundary: Boundary
    let outline: BoundaryOutline
    /// Screen rect of `outline.bounds` (animates with the layout).
    let rect: CGRect
    let color: Color
    let scale: CGFloat
    let isSelected: Bool

    private var cornerRadius: CGFloat { 12 * scale }

    var body: some View {
        let shape = HullShape(outline: outline, cornerRadius: cornerRadius)
        let hit = BoundaryHitShape(outline: shape, band: EditorController.hitTolerance,
                                   tab: boundary.hasLabel ? tabRect : nil)
        ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(0.06))
            HatchShape(spacing: 9 * scale).stroke(color.opacity(0.16), lineWidth: max(0.75, scale))
                .clipShape(shape)
            if isSelected {
                shape.stroke(Color.accentColor.opacity(0.35), lineWidth: 6 * max(scale, 0.5))
            }
            shape.stroke(color.opacity(isSelected ? 1 : 0.8),
                         style: StrokeStyle(lineWidth: (isSelected ? 2.5 : 1.5) * scale,
                                            dash: [6 * scale, 4 * scale]))
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

    /// Label tab in the view's own coordinates (top-left of the label piece).
    private var tabRect: CGRect {
        let bounds = outline.bounds
        let sx = bounds.width > 0 ? rect.width / bounds.width : scale
        let sy = bounds.height > 0 ? rect.height / bounds.height : scale
        return CGRect(x: (outline.labelOrigin.x - bounds.minX) * sx, y: (outline.labelOrigin.y - bounds.minY) * sy,
                      width: min(CanvasHitTester.boundaryTabWidth, outline.labelWidth) * sx,
                      height: LayoutSpacing().boundaryLabelHeight * sy)
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
                .offset(x: tabRect.minX, y: tabRect.minY)
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

/// A boundary outline with rounded corners. The polygon is stored relative
/// to its bounds, so it follows the (animated) frame it is drawn in.
struct HullShape: Shape {
    var outline: BoundaryOutline
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let bounds = outline.bounds
        guard bounds.width > 0, bounds.height > 0 else { return Path(rect) }
        let sx = rect.width / bounds.width, sy = rect.height / bounds.height
        return Path(BoundaryHull.roundedPath(outline.polygon, radius: cornerRadius) { point in
            CGPoint(x: rect.minX + (point.x - bounds.minX) * sx, y: rect.minY + (point.y - bounds.minY) * sy)
        })
    }
}

/// Outline band (± `band`) of a boundary plus an optional label tab.
struct BoundaryHitShape: Shape {
    var outline: HullShape
    var band: CGFloat
    var tab: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = outline.path(in: rect).strokedPath(StrokeStyle(lineWidth: band * 2))
        if let tab { path.addRect(tab.offsetBy(dx: rect.minX, dy: rect.minY)) }
        return path
    }
}
