import CoreGraphics
import Foundation

/// Where a dragged topic lands relative to the hovered topic.
enum DropPlacement: Equatable {
    /// Becomes the last child of the target (reparent).
    case child
    /// Inserted as a sibling before / after the target (reorder).
    case before, after
}

/// Hit-testing for drag-to-reparent / reorder (pure).
enum DropTargetFinder {
    /// Extra tolerance around node frames.
    static let slop: CGFloat = 6
    /// Fraction of the frame (along the sibling axis) at each end that
    /// means "insert before/after" instead of "make child".
    static let edgeFraction: CGFloat = 0.25

    /// The smallest visible node frame (grown by `slop`) containing `point`,
    /// ignoring `excluded` ids (the dragged subtree).
    static func target(at point: CGPoint, frames: [UUID: CGRect], excluding excluded: Set<UUID>) -> UUID? {
        var best: (id: UUID, area: CGFloat)?
        for (id, frame) in frames where !excluded.contains(id) {
            guard frame.insetBy(dx: -slop, dy: -slop).contains(point) else { continue }
            let area = frame.width * frame.height
            if best == nil || area < best!.area || (area == best!.area && id.uuidString < best!.id.uuidString) {
                best = (id, area)
            }
        }
        return best?.id
    }

    /// Placement for `point` over `frame`. `siblingAxis` is the axis along
    /// which the target's siblings are stacked (nil = target cannot have
    /// siblings, e.g. a root: always `.child`).
    static func placement(at point: CGPoint, in frame: CGRect, siblingAxis: ConnectorAxis?) -> DropPlacement {
        guard let siblingAxis else { return .child }
        let (value, lower, length) = siblingAxis == .vertical
            ? (point.y, frame.minY, frame.height) : (point.x, frame.minX, frame.width)
        let edge = length * edgeFraction
        if value < lower + edge { return .before }
        if value > lower + length - edge { return .after }
        return .child
    }

    /// Index for `TreeEdit.move` / reparent (list after removing the moving
    /// node) when dropping before/after the sibling at `targetIndex`.
    /// `movingIndex` = index of the moving node in the same parent, or nil
    /// if it comes from another parent.
    static func insertionIndex(targetIndex: Int, placement: DropPlacement, movingIndex: Int?) -> Int {
        var index = targetIndex + (placement == .after ? 1 : 0)
        if let movingIndex, movingIndex < index { index -= 1 }
        return index
    }
}
