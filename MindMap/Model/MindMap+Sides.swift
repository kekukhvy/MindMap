import CoreGraphics
import Foundation

/// Stable sides of balanced-map branches (WP17). A child of a balanced map
/// (the central topic) gets its `Node.side` once and keeps it: expanding,
/// collapsing, adding or deleting other topics never moves it across the
/// root. Only "Rebalance Map" and dragging it to the other side change it.
extension MindMap {
    /// Topics whose children are split left / right: the central topic
    /// (unless it sets another layout) and any topic set to `.balancedMap`.
    func balancedParents() -> [Node] {
        var result: [Node] = []
        func visit(_ node: Node, isRoot: Bool) {
            let style = node.layoutStyle ?? (isRoot ? LayoutStyle.rootDefault : nil)
            if style == .balancedMap, !node.children.isEmpty { result.append(node) }
            for child in node.children { visit(child, isRoot: false) }
        }
        visit(root, isRoot: true)
        for topic in floatingTopics { visit(topic.node, isRoot: false) }
        return result
    }

    /// Whether `id`'s children are split left / right.
    func isBalancedParent(_ id: UUID) -> Bool {
        guard let node = node(withID: id) else { return false }
        return (node.layoutStyle ?? (id == root.id ? LayoutStyle.rootDefault : nil)) == .balancedMap
    }

    /// Edits putting `ids` on `side` of `parent` when it is a balanced map
    /// (drag and drop to one side of the central topic); none otherwise.
    func sideEdits(_ ids: [UUID], side: BranchSide?, parent: UUID) -> [MapEdit] {
        guard let side, isBalancedParent(parent) else { return [] }
        return ids.map { .tree(.set(id: $0, .side(side))) }
    }

    /// Edits storing the sides the layout shows now for children that have
    /// none yet (older files): `split` = the layout's split per parent.
    func sidePinEdits(split: [UUID: BalancedSplit]) -> [MapEdit] {
        var edits: [MapEdit] = []
        for parent in balancedParents() {
            for child in parent.children where child.side == nil {
                let side = child.manualPosition.map(BranchSide.init(manualOffset:))
                    ?? split[parent.id]?.sides[child.id]
                if let side { edits.append(.tree(.set(id: child.id, .side(side)))) }
            }
        }
        return edits
    }

    /// Edits giving a side to children of balanced parents that need one
    /// after an edit (`self` = the edited map, `previous` = before it):
    /// - a free (manually positioned) child: the side it was dropped on;
    /// - a new child, one moved in from another parent, or one without a
    ///   side: the side that is lighter at that point (ties: right),
    ///   unless `explicit` (sides the edit set itself) has it.
    /// `split` (the layout before the edit) gives the subtree heights.
    func sideAssignmentEdits(previous: MindMap, explicit: Set<UUID>,
                             split: [UUID: BalancedSplit]) -> [MapEdit] {
        var edits: [MapEdit] = []
        for parent in balancedParents() {
            let before = previous.node(withID: parent.id).map { Set($0.children.map(\.id)) } ?? []
            let heights = split[parent.id]?.heights ?? [:]
            var weights: [BranchSide: CGFloat] = [.left: 0, .right: 0]
            var pending: [Node] = []
            for child in parent.children {
                if let offset = child.manualPosition {
                    let side = BranchSide(manualOffset: offset)
                    if child.side != side { edits.append(.tree(.set(id: child.id, .side(side)))) }
                    continue
                }
                let isNew = !before.contains(child.id)
                if let side = child.side, explicit.contains(child.id) || !isNew {
                    weights[side, default: 0] += heights[child.id] ?? MindMap.estimatedHeight(of: child)
                } else {
                    pending.append(child)
                }
            }
            let stacked = parent.children.filter { $0.manualPosition == nil }
            if !pending.isEmpty, pending.count == stacked.count {
                // A topic that just became a balanced map: the classic split
                // (leading children right), as the layout shows it.
                let sides = BalancedSplit.sides(stored: pending.map { _ in nil }, heights: pending.map {
                    heights[$0.id] ?? MindMap.estimatedHeight(of: $0)
                })
                for (child, side) in zip(pending, sides) where child.side != side {
                    edits.append(.tree(.set(id: child.id, .side(side))))
                }
                continue
            }
            for child in pending {
                let side: BranchSide = weights[.left, default: 0] < weights[.right, default: 0] ? .left : .right
                weights[side, default: 0] += heights[child.id] ?? MindMap.estimatedHeight(of: child)
                if child.side != side { edits.append(.tree(.set(id: child.id, .side(side)))) }
            }
        }
        return edits
    }

    /// Edits for "Rebalance Map": every balanced parent's auto-laid
    /// children split again by subtree height (leading children right),
    /// as a new map would be. Free children keep the side they sit on.
    func rebalanceEdits(split: [UUID: BalancedSplit]) -> [MapEdit] {
        var edits: [MapEdit] = []
        for parent in balancedParents() {
            let stacked = parent.children.filter { $0.manualPosition == nil }
            let heights = stacked.map { split[parent.id]?.heights[$0.id] ?? MindMap.estimatedHeight(of: $0) }
            let sides = BalancedSplit.sides(stored: stacked.map { _ in nil }, heights: heights)
            for (child, side) in zip(stacked, sides) where child.side != side {
                edits.append(.tree(.set(id: child.id, .side(side))))
            }
        }
        return edits
    }

    /// Rough stacked height of a subtree without measuring (used only when
    /// no measured layout is at hand): visible leaf rows.
    static func estimatedHeight(of node: Node) -> CGFloat {
        func rows(_ node: Node) -> Int {
            guard !node.isCollapsed, !node.children.isEmpty else { return 1 }
            return node.children.reduce(0) { $0 + rows($1) }
        }
        return CGFloat(rows(node)) * 36
    }

    /// Layout with estimated topic sizes (no text measuring), for side
    /// decisions when no measured layout is available (headless use).
    func estimatedSplit() -> [UUID: BalancedSplit] {
        TreeLayout().layout(self) { id in
            let text = self.node(withID: id)?.text ?? ""
            return CGSize(width: 24 + CGFloat(min(text.count, 40)) * 7, height: id == self.root.id ? 48 : 30)
        }.balanced
    }
}
