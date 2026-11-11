import CoreGraphics
import Foundation

/// Org chart: children side by side in a row below the parent, the row
/// centered under the parent; child nodes' tops are aligned.
struct OrgChartArranger: SubtreeArranger {
    func arrange(
        _ node: Node,
        nodeSize: CGSize,
        context: LayoutContext,
        spacing: LayoutSpacing,
        layoutChild: (Node, LayoutContext) -> SubtreeLayout
    ) -> SubtreeLayout {
        var result = SubtreeLayout(id: node.id, size: nodeSize)
        let childContext = context.passingDown(style: .orgChartDown, direction: context.direction)
        let children = node.children.map {
            ChildSubtree(id: $0.id, layout: layoutChild($0, childContext))
        }
        guard !children.isEmpty else { return result }

        let totalWidth = children.reduce(0) { $0 + $1.layout.bounds.width }
            + spacing.rowGap * CGFloat(children.count - 1)
        // Extent of each subtree above its own node (local node top is y = 0).
        let maxAbove = children.map { -$0.layout.bounds.minY }.max() ?? 0
        let nodeTop = nodeSize.height + spacing.levelGap + maxAbove
        var cursorX = nodeSize.width / 2 - totalWidth / 2
        for child in children {
            let bounds = child.layout.bounds
            let dx = cursorX - bounds.minX
            result.merge(child.layout, dx: dx, dy: nodeTop)
            let frame = child.nodeFrame.offsetBy(dx: dx, dy: nodeTop)
            result.connectors.append(context.connector(
                from: node.id, to: child.id,
                start: CGPoint(x: nodeSize.width / 2, y: nodeSize.height),
                end: CGPoint(x: frame.midX, y: frame.minY),
                axes: (.vertical, .vertical), defaultStyle: .elbow
            ))
            cursorX += bounds.width + spacing.rowGap
        }
        return result
    }
}
