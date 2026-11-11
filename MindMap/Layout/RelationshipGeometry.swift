import CoreGraphics
import Foundation

/// Resolved geometry of a relationship: a cubic curve from `start` to `end`
/// (anchored on the node frames' edges) with two control points.
struct RelationshipPath: Equatable {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint
    /// Point on the curve at t = 0.5, for the label.
    var labelPoint: CGPoint
}

enum RelationshipGeometry {
    /// Default arc bulge as a fraction of the anchor distance.
    static let defaultBulge: CGFloat = 0.25

    static func path(from fromFrame: CGRect, to toFrame: CGRect, relationship: Relationship) -> RelationshipPath {
        let fromCenter = CGPoint(x: fromFrame.midX, y: fromFrame.midY)
        let toCenter = CGPoint(x: toFrame.midX, y: toFrame.midY)
        let start = anchor(on: fromFrame, toward: toCenter)
        let end = anchor(on: toFrame, toward: fromCenter)
        let dx = end.x - start.x, dy = end.y - start.y
        // Perpendicular (rotated -90°) scaled bulge for the automatic arc.
        let bulge = CGVector(dx: dy * defaultBulge, dy: -dx * defaultBulge)
        let o1 = relationship.fromControlOffset ?? CGVector(dx: dx / 3 + bulge.dx, dy: dy / 3 + bulge.dy)
        let o2 = relationship.toControlOffset ?? CGVector(dx: -dx / 3 + bulge.dx, dy: -dy / 3 + bulge.dy)
        let c1 = CGPoint(x: start.x + o1.dx, y: start.y + o1.dy)
        let c2 = CGPoint(x: end.x + o2.dx, y: end.y + o2.dy)
        let label = CGPoint(
            x: 0.125 * start.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * end.x,
            y: 0.125 * start.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * end.y
        )
        return RelationshipPath(start: start, control1: c1, control2: c2, end: end, labelPoint: label)
    }

    /// Point where the ray from the rect's center toward `target` leaves the rect.
    static func anchor(on rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x, dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let sx = dx == 0 ? CGFloat.infinity : (rect.width / 2) / abs(dx)
        let sy = dy == 0 ? CGFloat.infinity : (rect.height / 2) / abs(dy)
        let scale = min(sx, sy)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}
