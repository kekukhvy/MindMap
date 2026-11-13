import CoreGraphics
import Foundation

/// XMind "Mind Map": children split into a right group and a left group.
/// Each child keeps its stored `Node.side` (WP17: expanding / collapsing
/// never moves a branch across the node); children without one are split
/// by subtree height (`BalancedSplit.sides`). Each group keeps document
/// order top to bottom. The left group grows leftwards (mirrored) and its
/// descendants inherit the left direction.
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
        let heights = measured.map { $0.layout.bounds.height }
        let sides = BalancedSplit.sides(stored: node.children.map(\.side), heights: heights)
        var right: [ChildSubtree] = []
        var left: [ChildSubtree] = []
        for (index, child) in node.children.enumerated() {
            if sides[index] == .right {
                right.append(measured[index])
            } else {
                left.append(ChildSubtree(id: child.id, layout: layoutChild(child, context.horizontal(.left))))
            }
        }
        HorizontalArranger.stack(right, side: .right, parentID: node.id, nodeSize: nodeSize,
                                 context: context, spacing: spacing, into: &result)
        HorizontalArranger.stack(left, side: .left, parentID: node.id, nodeSize: nodeSize,
                                 context: context, spacing: spacing, into: &result)
        let ids = node.children.map(\.id)
        result.balanced[node.id] = BalancedSplit(order: ids, sides: Dictionary(uniqueKeysWithValues: zip(ids, sides)),
                                                 heights: Dictionary(uniqueKeysWithValues: zip(ids, heights)))
        return result
    }

    /// Classic split (kept for callers / tests): see `BalancedSplit.rightCount`.
    static func rightCount(heights: [CGFloat]) -> Int {
        BalancedSplit.rightCount(heights: heights)
    }
}
