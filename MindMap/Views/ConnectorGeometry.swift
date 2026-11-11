import SwiftUI

/// Drawable branch line (pure geometry, map or screen coordinates).
/// Follows the renderer rules documented on `Connector`.
struct ConnectorGeometry: Equatable {
    var start: CGPoint
    var end: CGPoint
    var startAxis: ConnectorAxis
    var endAxis: ConnectorAxis
    var style: ConnectorStyle
    var startWidth: CGFloat
    var endWidth: CGFloat
    var dash: LineDash

    /// XMind-like tapered curve: filled outline instead of a stroke.
    var isTapered: Bool {
        style == .curved && dash == .solid && abs(startWidth - endWidth) > 0.01
    }

    func transformed(by viewport: Viewport) -> ConnectorGeometry {
        var copy = self
        copy.start = viewport.toScreen(start)
        copy.end = viewport.toScreen(end)
        copy.startWidth = startWidth * viewport.scale
        copy.endWidth = endWidth * viewport.scale
        return copy
    }

    /// Path to stroke (or, if tapered, to fill).
    func path() -> Path {
        isTapered ? taperedOutline() : centerline()
    }

    func centerline() -> Path {
        var path = Path()
        path.move(to: start)
        switch style {
        case .straight:
            path.addLine(to: end)
        case .curved:
            let (c1, c2) = controlPoints()
            path.addCurve(to: end, control1: c1, control2: c2)
        case .elbow:
            for point in elbowPoints().dropFirst() { path.addLine(to: point) }
        case .roundedElbow:
            let points = elbowPoints()
            for index in 1..<points.count - 1 {
                let previous = points[index - 1], corner = points[index], next = points[index + 1]
                let radius = min(10, distance(previous, corner) / 2, distance(corner, next) / 2)
                if radius > 0.5 {
                    path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
                } else {
                    path.addLine(to: corner)
                }
            }
            path.addLine(to: end)
        }
        return path
    }

    /// Control points with tangents along the axes at both ends.
    func controlPoints() -> (CGPoint, CGPoint) {
        let c1 = startAxis == .horizontal
            ? CGPoint(x: start.x + (end.x - start.x) / 2, y: start.y)
            : CGPoint(x: start.x, y: start.y + (end.y - start.y) / 2)
        let c2 = endAxis == .horizontal
            ? CGPoint(x: end.x - (end.x - start.x) / 2, y: end.y)
            : CGPoint(x: end.x, y: end.y - (end.y - start.y) / 2)
        return (c1, c2)
    }

    /// Orthogonal polyline: H→H via mid-x, V→H down then across,
    /// V→V via mid-y, H→V across then down.
    func elbowPoints() -> [CGPoint] {
        switch (startAxis, endAxis) {
        case (.horizontal, .horizontal):
            let midX = (start.x + end.x) / 2
            return [start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end]
        case (.vertical, .horizontal):
            return [start, CGPoint(x: start.x, y: end.y), end]
        case (.vertical, .vertical):
            let midY = (start.y + end.y) / 2
            return [start, CGPoint(x: start.x, y: midY), CGPoint(x: end.x, y: midY), end]
        case (.horizontal, .vertical):
            return [start, CGPoint(x: end.x, y: start.y), end]
        }
    }

    private func taperedOutline() -> Path {
        let (c1, c2) = controlPoints()
        let n0 = normal(startAxis), n1 = normal(endAxis)
        let h0 = startWidth / 2, h1 = endWidth / 2
        func shift(_ p: CGPoint, _ n: CGVector, _ amount: CGFloat) -> CGPoint {
            CGPoint(x: p.x + n.dx * amount, y: p.y + n.dy * amount)
        }
        var path = Path()
        path.move(to: shift(start, n0, h0))
        path.addCurve(to: shift(end, n1, h1), control1: shift(c1, n0, h0), control2: shift(c2, n1, h1))
        path.addLine(to: shift(end, n1, -h1))
        path.addCurve(to: shift(start, n0, -h0), control1: shift(c2, n1, -h1), control2: shift(c1, n0, -h0))
        path.closeSubpath()
        return path
    }

    private func normal(_ axis: ConnectorAxis) -> CGVector {
        axis == .horizontal ? CGVector(dx: 0, dy: 1) : CGVector(dx: 1, dy: 0)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// Dash pattern for stroked lines of `width`.
    static func dashPattern(_ dash: LineDash, width: CGFloat) -> [CGFloat] {
        switch dash {
        case .solid: return []
        case .dashed: return [max(4, width * 3), max(3, width * 2)]
        case .dotted: return [0.1, max(3, width * 2.5)]
        }
    }
}

/// Animatable shape for one connector (endpoints animate on layout changes).
struct ConnectorShape: Shape {
    var geometry: ConnectorGeometry

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(geometry.start.x, geometry.start.y),
                           AnimatablePair(geometry.end.x, geometry.end.y))
        }
        set {
            geometry.start = CGPoint(x: newValue.first.first, y: newValue.first.second)
            geometry.end = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        geometry.path()
    }
}
