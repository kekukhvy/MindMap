import CoreGraphics
import Foundation

/// Side of a balanced-map parent (the central topic) a child branch sits
/// on (`Node.side`, JSON "left" / "right").
enum BranchSide: String, Codable, CaseIterable {
    case left, right

    var opposite: BranchSide { self == .left ? .right : .left }

    /// Side of a freely positioned child at `offset` from its parent's center.
    init(manualOffset offset: CGPoint) {
        self = offset.x < 0 ? .left : .right
    }
}

/// How a balanced-map node split its auto-laid children (reported by the
/// layout for side pinning and "Rebalance Map").
struct BalancedSplit: Equatable {
    /// Auto-laid children in document order.
    var order: [UUID]
    var sides: [UUID: BranchSide]
    /// Subtree height of each child (its stacking extent).
    var heights: [UUID: CGFloat]

    /// Total stacked height per side.
    func weight(of side: BranchSide) -> CGFloat {
        order.reduce(0) { $0 + (sides[$1] == side ? heights[$1] ?? 0 : 0) }
    }

    /// Sides for `heights` (document order) given the children's stored
    /// sides: none stored = the classic split (leading children right while
    /// the right side stays closest to half the total height); otherwise
    /// stored sides are kept and each unassigned child goes to the side
    /// that is lighter at that point (ties: right).
    static func sides(stored: [BranchSide?], heights: [CGFloat]) -> [BranchSide] {
        if stored.allSatisfy({ $0 == nil }) {
            let right = rightCount(heights: heights)
            return heights.indices.map { $0 < right ? .right : .left }
        }
        var weights: [BranchSide: CGFloat] = [.left: 0, .right: 0]
        for (side, height) in zip(stored, heights) {
            if let side { weights[side, default: 0] += height }
        }
        var result: [BranchSide] = []
        for (side, height) in zip(stored, heights) {
            let chosen = side ?? (weights[.left, default: 0] < weights[.right, default: 0] ? .left : .right)
            if side == nil { weights[chosen, default: 0] += height }
            result.append(chosen)
        }
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
