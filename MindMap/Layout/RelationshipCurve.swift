import CoreGraphics
import Foundation

/// Pure drawing/hit-testing geometry of a relationship for its path style
/// (map or screen coordinates): polyline approximation, tangent points for
/// arrowheads, and distance from a point (for selection).
enum RelationshipCurve {
    /// Orthogonal corner points of an elbow relationship (H, V at mid-x, H).
    static func elbowCorners(_ path: RelationshipPath) -> (CGPoint, CGPoint) {
        let midX = (path.start.x + path.end.x) / 2
        return (CGPoint(x: midX, y: path.start.y), CGPoint(x: midX, y: path.end.y))
    }

    /// Point on the cubic at parameter `t` (0...1).
    static func point(on path: RelationshipPath, at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * path.start.x + b * path.control1.x + c * path.control2.x + d * path.end.x,
                       y: a * path.start.y + b * path.control1.y + c * path.control2.y + d * path.end.y)
    }

    /// Polyline following the drawn line (curves sampled in `segments`).
    static func polyline(_ path: RelationshipPath, style: RelationshipPathStyle, segments: Int = 32) -> [CGPoint] {
        switch style {
        case .straight:
            return [path.start, path.end]
        case .elbow:
            let (p1, p2) = elbowCorners(path)
            return [path.start, p1, p2, path.end]
        case .curved:
            let count = max(segments, 1)
            return (0...count).map { point(on: path, at: CGFloat($0) / CGFloat(count)) }
        }
    }

    /// Points the line arrives from at the start / end (arrowhead direction).
    static func tangentPoints(_ path: RelationshipPath, style: RelationshipPathStyle)
        -> (afterStart: CGPoint, beforeEnd: CGPoint) {
        switch style {
        case .curved:
            // Degenerate control points fall back to the opposite end.
            let after = path.control1 == path.start ? path.end : path.control1
            let before = path.control2 == path.end ? path.start : path.control2
            return (after, before)
        case .straight:
            return (path.end, path.start)
        case .elbow:
            let (p1, p2) = elbowCorners(path)
            return (p1 == path.start ? p2 : p1, p2 == path.end ? p1 : p2)
        }
    }

    /// Shortest distance from `point` to the drawn line.
    static func distance(from point: CGPoint, to path: RelationshipPath, style: RelationshipPathStyle) -> CGFloat {
        let points = polyline(path, style: style)
        guard points.count > 1 else { return hypot(point.x - path.start.x, point.y - path.start.y) }
        var best = CGFloat.infinity
        for index in 1..<points.count {
            best = min(best, segmentDistance(point, points[index - 1], points[index]))
        }
        return best
    }

    static func hits(_ point: CGPoint, path: RelationshipPath, style: RelationshipPathStyle,
                     tolerance: CGFloat) -> Bool {
        distance(from: point, to: path, style: style) <= tolerance
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Recomputes the label point after moving control points.
    static func withControls(_ path: RelationshipPath, control1: CGPoint, control2: CGPoint) -> RelationshipPath {
        var result = path
        result.control1 = control1
        result.control2 = control2
        result.labelPoint = point(on: result, at: 0.5)
        return result
    }
}
