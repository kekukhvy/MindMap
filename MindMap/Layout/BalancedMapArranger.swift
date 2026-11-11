import CoreGraphics
import Foundation

/// XMind "Mind Map": children split into a right group (first children)
/// and a left group, balanced by subtree height. The left group grows
/// leftwards (mirrored) and its descendants inherit the left direction.
struct BalancedMapArranger: SubtreeArranger {
    func arrange(
        _ node: Node,
        nodeSize: CGSize,
        context: LayoutContext,
        spacing: LayoutSpacing,
        layoutChild: (Node, LayoutContext) -> SubtreeLayout
    ) -> SubtreeLayout {
        var result = SubtreeLayout(id: node.id, size: nodeSize)
        let measured = node.children.map {
            ChildSubtree(id: $0.id, layout: layoutChild($0, context.horizontal(.right)))
        }
        let rightCount = BalancedMapArranger.rightCount(heights: measured.map { $0.layout.bounds.height })
        let right = Array(measured.prefix(rightCount))
        let left = node.children.dropFirst(rightCount).map {
            ChildSubtree(id: $0.id, layout: layoutChild($0, context.horizontal(.left)))
        }
        HorizontalArranger.stack(right, side: .right, parentID: node.id, nodeSize: nodeSize,
                                 context: context, spacing: spacing, into: &result)
        HorizontalArranger.stack(left, side: .left, parentID: node.id, nodeSize: nodeSize,
                                 context: context, spacing: spacing, into: &result)
        return result
    }

    /// Number of leading children placed on the right: the right side takes
    /// children while its total height stays closest to half of the total.
    static func rightCount(heights: [CGFloat]) -> Int {
        guard heights.count > 1 else { return heights.count }
        let total = heights.reduce(0, +)
        var sum: CGFloat = 0
        var count = 0
        for height in heights {
            if count > 0 && sum + height / 2 > total / 2 { break }
            sum += height
            count += 1
        }
        return min(count, heights.count - 1)
    }
}
