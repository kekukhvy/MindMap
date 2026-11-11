import CoreGraphics
import Foundation

/// Strategy for one `LayoutStyle`: lays out a node's visible children
/// (via `layoutChild`) and places them around the node's frame at origin.
/// Placed child subtrees must not overlap each other or the node.
protocol SubtreeArranger {
    func arrange(
        _ node: Node,
        nodeSize: CGSize,
        context: LayoutContext,
        spacing: LayoutSpacing,
        layoutChild: (Node, LayoutContext) -> SubtreeLayout
    ) -> SubtreeLayout
}

enum Arrangers {
    static func arranger(for style: LayoutStyle) -> SubtreeArranger {
        switch style {
        case .balancedMap: return BalancedMapArranger()
        case .rightMap: return HorizontalArranger(direction: .right)
        case .leftMap: return HorizontalArranger(direction: .left)
        case .treeDown: return TreeDownArranger()
        case .orgChartDown: return OrgChartArranger()
        }
    }
}
