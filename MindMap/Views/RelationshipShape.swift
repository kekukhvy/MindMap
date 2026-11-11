import SwiftUI

extension RelationshipPath {
    func transformed(by viewport: Viewport) -> RelationshipPath {
        RelationshipPath(start: viewport.toScreen(start), control1: viewport.toScreen(control1),
                         control2: viewport.toScreen(control2), end: viewport.toScreen(end),
                         labelPoint: viewport.toScreen(labelPoint))
    }
}

/// Animatable relationship line or one of its arrowheads (screen
/// coordinates, drawn in a full-canvas frame). Interpolates the four
/// curve points so relationships follow layout animations.
struct RelationshipShape: Shape {
    enum Part: Equatable {
        case line
        case startHead(ArrowHead, length: CGFloat)
        case endHead(ArrowHead, length: CGFloat)
    }

    var geometry: RelationshipPath
    var pathStyle: RelationshipPathStyle
    var part: Part

    typealias Pair = AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>

    var animatableData: AnimatablePair<Pair, Pair> {
        get {
            AnimatablePair(Pair(geometry.start.animatableData, geometry.control1.animatableData),
                           Pair(geometry.control2.animatableData, geometry.end.animatableData))
        }
        set {
            geometry.start.animatableData = newValue.first.first
            geometry.control1.animatableData = newValue.first.second
            geometry.control2.animatableData = newValue.second.first
            geometry.end.animatableData = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        switch part {
        case .line:
            return line()
        case let .startHead(head, length):
            let tangent = RelationshipCurve.tangentPoints(geometry, style: pathStyle).afterStart
            return RelationshipShape.head(head, tip: geometry.start, from: tangent, length: length)
        case let .endHead(head, length):
            let tangent = RelationshipCurve.tangentPoints(geometry, style: pathStyle).beforeEnd
            return RelationshipShape.head(head, tip: geometry.end, from: tangent, length: length)
        }
    }

    private func line() -> Path {
        var path = Path()
        path.move(to: geometry.start)
        switch pathStyle {
        case .curved:
            path.addCurve(to: geometry.end, control1: geometry.control1, control2: geometry.control2)
        case .straight:
            path.addLine(to: geometry.end)
        case .elbow:
            let (p1, p2) = RelationshipCurve.elbowCorners(geometry)
            path.addLine(to: p1)
            path.addLine(to: p2)
            path.addLine(to: geometry.end)
        }
        return path
    }

    /// Arrowhead outline (`.arrow` is meant to be stroked, others filled).
    static func head(_ head: ArrowHead, tip: CGPoint, from previous: CGPoint, length: CGFloat) -> Path {
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        func point(_ distance: CGFloat, _ offset: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - cos(angle) * distance - sin(angle) * offset,
                    y: tip.y - sin(angle) * distance + cos(angle) * offset)
        }
        var path = Path()
        switch head {
        case .none:
            break
        case .arrow:
            path.move(to: point(length, length * 0.5))
            path.addLine(to: tip)
            path.addLine(to: point(length, -length * 0.5))
        case .filledArrow:
            path.move(to: tip)
            path.addLine(to: point(length, length * 0.5))
            path.addLine(to: point(length, -length * 0.5))
            path.closeSubpath()
        case .dot:
            let radius = length * 0.35
            let center = point(radius, 0)
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        case .diamond:
            path.move(to: tip)
            path.addLine(to: point(length * 0.5, length * 0.35))
            path.addLine(to: point(length, 0))
            path.addLine(to: point(length * 0.5, -length * 0.35))
            path.closeSubpath()
        }
        return path
    }
}

/// Hit area of a relationship: a band of `tolerance` around the drawn line
/// (same polyline as `RelationshipCurve.distance`).
struct RelationshipHitShape: Shape {
    var geometry: RelationshipPath
    var pathStyle: RelationshipPathStyle
    var tolerance: CGFloat

    func path(in rect: CGRect) -> Path {
        var line = Path()
        line.addLines(RelationshipCurve.polyline(geometry, style: pathStyle))
        return line.strokedPath(StrokeStyle(lineWidth: tolerance * 2, lineCap: .round, lineJoin: .round))
    }
}
