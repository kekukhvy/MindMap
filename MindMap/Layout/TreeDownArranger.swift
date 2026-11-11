import CoreGraphics
import Foundation

/// MindManager "tree chart": children stacked one under another below the
/// parent, indented towards the branch direction, with (default) elbow
/// connectors starting at the parent's lower-left (lower-right when mirrored).
struct TreeDownArranger: SubtreeArranger {
    func arrange(
        _ node: Node,
        nodeSize: CGSize,
        context: LayoutContext,
        spacing: LayoutSpacing,
        layoutChild: (Node, LayoutContext) -> SubtreeLayout
    ) -> SubtreeLayout {
        var result = SubtreeLayout(id: node.id, size: nodeSize)
        let isRight = context.direction == .right
        let childContext = context.passingDown(style: .treeDown, direction: context.direction)
        let railX = isRight ? spacing.treeIndent / 2 : nodeSize.width - spacing.treeIndent / 2
        var cursorY = nodeSize.height + spacing.levelGap
        for child in node.children {
            let layout = layoutChild(child, childContext)
            let bounds = layout.bounds
            let dx = isRight
                ? spacing.treeIndent - bounds.minX
                : nodeSize.width - spacing.treeIndent - bounds.maxX
            let dy = cursorY - bounds.minY
            result.merge(layout, dx: dx, dy: dy)
            let frame = (layout.frames[child.id] ?? .zero).offsetBy(dx: dx, dy: dy)
            result.connectors.append(context.connector(
                from: node.id, to: child.id,
                start: CGPoint(x: railX, y: nodeSize.height),
                end: CGPoint(x: isRight ? frame.minX : frame.maxX, y: frame.midY),
                axes: (.vertical, .horizontal), defaultStyle: .elbow
            ))
            cursorY += bounds.height + spacing.vertical
        }
        return result
    }
}
