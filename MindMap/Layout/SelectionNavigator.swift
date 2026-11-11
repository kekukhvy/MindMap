import CoreGraphics
import Foundation

/// Arrow-key direction.
enum MoveDirection: CaseIterable, Equatable {
    case up, down, left, right

    var opposite: MoveDirection {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }

    var isVertical: Bool { self == .up || self == .down }
}

/// Direction-aware selection movement over a laid-out map (pure).
/// Rules, derived from each node's incoming connector:
/// - the key pointing back to the parent selects the parent
///   (Left on right-side branches, Right on left-side ones, Left/Right in
///   tree charts, Up in org charts);
/// - the opposite key selects the nearest visible child on that side;
/// - keys along the sibling axis move to the nearest sibling on the same
///   side, falling back to the geometrically nearest node (cousins);
/// - roots (no parent) use geometric movement for keys without children.
struct SelectionNavigator {
    private let frames: [UUID: CGRect]
    private let incoming: [UUID: Connector]
    private let children: [UUID: [UUID]]

    init(frames: [UUID: CGRect], connectors: [Connector]) {
        self.frames = frames
        var incoming: [UUID: Connector] = [:]
        var children: [UUID: [UUID]] = [:]
        for connector in connectors {
            incoming[connector.childID] = connector
            children[connector.parentID, default: []].append(connector.childID)
        }
        self.incoming = incoming
        self.children = children
    }

    init(layout: TreeLayout.Result) {
        self.init(frames: layout.frames, connectors: layout.connectors)
    }

    /// Direction from the child towards its parent for an edge.
    static func directionToParent(_ connector: Connector) -> MoveDirection {
        if connector.endAxis == .vertical {
            return connector.end.y >= connector.start.y ? .up : .down
        }
        return connector.end.x >= connector.start.x ? .left : .right
    }

    /// Siblings are stacked vertically unless the edge enters from above (org chart).
    static func siblingsStackVertically(_ connector: Connector) -> Bool {
        connector.endAxis == .horizontal
    }

    /// Direction from `id` towards its parent (nil for roots).
    func directionToParent(of id: UUID) -> MoveDirection? {
        incoming[id].map(SelectionNavigator.directionToParent)
    }

    func target(from id: UUID, direction: MoveDirection) -> UUID? {
        guard let frame = frames[id] else { return nil }
        let edge = incoming[id]
        if let edge, SelectionNavigator.directionToParent(edge) == direction {
            return edge.parentID
        }
        let kids = (children[id] ?? []).filter { directionToParent(of: $0) == direction.opposite }
        if let best = nearest(kids, to: frame) { return best }
        guard let edge else { return geometricTarget(from: id, direction: direction) }
        guard direction.isVertical == SelectionNavigator.siblingsStackVertically(edge) else { return nil }
        let side = SelectionNavigator.directionToParent(edge)
        let ahead = (children[edge.parentID] ?? []).filter { sibling in
            guard sibling != id, directionToParent(of: sibling) == side, let other = frames[sibling] else {
                return false
            }
            return SelectionNavigator.offset(from: frame, to: other, along: direction).primary > 0.5
        }
        let best = ahead.min { lhs, rhs in
            distance(frame, frames[lhs]) < distance(frame, frames[rhs])
        }
        return best ?? geometricTarget(from: id, direction: direction)
    }

    /// Nearest node whose center lies in `direction`, preferring alignment.
    func geometricTarget(from id: UUID, direction: MoveDirection) -> UUID? {
        guard let frame = frames[id] else { return nil }
        var best: (id: UUID, score: CGFloat)?
        for (other, otherFrame) in frames where other != id {
            let offset = SelectionNavigator.offset(from: frame, to: otherFrame, along: direction)
            guard offset.primary > 0.5 else { continue }
            let score = offset.primary + 2 * abs(offset.secondary)
            if best == nil || score < best!.score || (score == best!.score && other.uuidString < best!.id.uuidString) {
                best = (other, score)
            }
        }
        return best?.id
    }

    private func nearest(_ ids: [UUID], to frame: CGRect) -> UUID? {
        ids.min { distance(frame, frames[$0]) < distance(frame, frames[$1]) }
    }

    private func distance(_ a: CGRect, _ b: CGRect?) -> CGFloat {
        guard let b else { return .infinity }
        return hypot(a.midX - b.midX, a.midY - b.midY)
    }

    /// Center offset split into the component along `direction` (positive =
    /// ahead) and the perpendicular component.
    static func offset(from a: CGRect, to b: CGRect, along direction: MoveDirection) -> (primary: CGFloat, secondary: CGFloat) {
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        switch direction {
        case .up: return (-dy, dx)
        case .down: return (dy, dx)
        case .left: return (-dx, dy)
        case .right: return (dx, dy)
        }
    }
}
