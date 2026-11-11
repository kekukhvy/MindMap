import CoreGraphics
import Foundation

/// Logic chart: all children on one side, stacked vertically, with the
/// parent vertically centered on the children block. Left mirrors right.
struct HorizontalArranger: SubtreeArranger {
    var direction: HorizontalDirection

    func arrange(
        _ node: Node,
        nodeSize: CGSize,
        context: LayoutContext,
        spacing: LayoutSpacing,
        layoutChild: (Node, LayoutContext) -> SubtreeLayout
    ) -> SubtreeLayout {
        var result = SubtreeLayout(id: node.id, size: nodeSize)
        let childContext = context.horizontal(direction)
        let children = node.children.map {
            ChildSubtree(id: $0.id, layout: layoutChild($0, childContext))
        }
        HorizontalArranger.stack(children, side: direction, parentID: node.id, nodeSize: nodeSize,
                                 context: context, spacing: spacing, into: &result)
        return result
    }

    /// Stacks `children` on `side` of the node and adds connectors.
    static func stack(
        _ children: [ChildSubtree],
        side: HorizontalDirection,
        parentID: UUID,
        nodeSize: CGSize,
        context: LayoutContext,
        spacing: LayoutSpacing,
        into result: inout SubtreeLayout
    ) {
        guard !children.isEmpty else { return }
        let total = children.reduce(0) { $0 + $1.layout.bounds.height }
            + spacing.vertical * CGFloat(children.count - 1)
        var cursorY = nodeSize.height / 2 - total / 2
        for child in children {
            let bounds = child.layout.bounds
            let dx = side == .right
                ? nodeSize.width + spacing.horizontal - bounds.minX
                : -spacing.horizontal - bounds.maxX
            let dy = cursorY - bounds.minY
            result.merge(child.layout, dx: dx, dy: dy)
            let childFrame = child.nodeFrame.offsetBy(dx: dx, dy: dy)
            let start = CGPoint(x: side == .right ? nodeSize.width : 0, y: nodeSize.height / 2)
            let end = CGPoint(x: side == .right ? childFrame.minX : childFrame.maxX, y: childFrame.midY)
            result.connectors.append(context.connector(
                from: parentID, to: child.id, start: start, end: end,
                axes: (.horizontal, .horizontal), defaultStyle: .curved
            ))
            cursorY += bounds.height + spacing.vertical
        }
    }
}
