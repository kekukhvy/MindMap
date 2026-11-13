import CoreGraphics
import Foundation
import PencilKit

/// An ideal shape recognized from a hand-drawn stroke (Apple Notes' "draw a
/// shape and hold": the wobbly stroke is replaced with a clean one).
enum RecognizedShape: Equatable {
    case line(from: CGPoint, to: CGPoint)
    case circle(center: CGPoint, radius: CGFloat)
    /// `angle`: rotation (radians) of the axis with radius `radii.width`.
    case ellipse(center: CGPoint, radii: CGSize, angle: CGFloat)
    /// Four corners in drawing order, right angles, possibly rotated.
    case rectangle(corners: [CGPoint])
    /// Three corners in drawing order.
    case triangle(corners: [CGPoint])

    /// Each corner is repeated this many times in `outline` so the cubic
    /// B-spline PencilKit draws through the points keeps it sharp.
    static let cornerRepeat = 3
    /// Fewest points on a circle / ellipse outline, whatever its size.
    static let minimumRoundPoints = 48

    /// Points along the outline about `spacing` apart. Closed shapes end
    /// where they start.
    func outline(spacing: CGFloat) -> [CGPoint] {
        switch self {
        case let .line(from, to):
            return Self.segment(from, to, spacing: spacing) + [to]
        case let .circle(center, radius):
            return Self.round(center: center, radii: CGSize(width: radius, height: radius), angle: 0, spacing: spacing)
        case let .ellipse(center, radii, angle):
            return Self.round(center: center, radii: radii, angle: angle, spacing: spacing)
        case let .rectangle(corners), let .triangle(corners):
            var points: [CGPoint] = []
            for (index, corner) in corners.enumerated() {
                let next = corners[(index + 1) % corners.count]
                points += Array(repeating: corner, count: Self.cornerRepeat - 1)
                points += Self.segment(corner, next, spacing: spacing)
            }
            return points + Array(repeating: corners[0], count: Self.cornerRepeat)
        }
    }

    /// Points from `a` (included) towards `b` (excluded).
    private static func segment(_ a: CGPoint, _ b: CGPoint, spacing: CGFloat) -> [CGPoint] {
        let count = max(1, Int((a.distance(to: b) / spacing).rounded(.up)))
        return (0..<count).map { a.interpolated(to: b, CGFloat($0) / CGFloat(count)) }
    }

    private static func round(center: CGPoint, radii: CGSize, angle: CGFloat, spacing: CGFloat) -> [CGPoint] {
        let circumference = 2 * CGFloat.pi * max(radii.width, radii.height)
        let count = max(minimumRoundPoints, Int((circumference / spacing).rounded(.up)))
        return (0...count).map { index in
            let t = 2 * CGFloat.pi * CGFloat(index) / CGFloat(count)
            let local = CGPoint(x: radii.width * cos(t), y: radii.height * sin(t))
            return center + local.rotated(by: angle)
        }
    }
}

/// Recognizes a stroke's points as a line, circle, ellipse, rectangle or
/// triangle; anything else is nil (the stroke stays as drawn).
///
/// Line: endpoints chord, small deviation, path not much longer than the chord.
/// Closed shapes (start and end close together): an ellipse fitted on the
/// principal axes and a polygon from the simplified path's corners (Ramer-Douglas-
/// Peucker, then corners by turn angle); the one closer to the points wins
/// if it is close enough. Thresholds are relative to the stroke's size.
enum ShapeRecognizer {
    /// Fewer points than this is a dot or a tap.
    static let minimumPointCount = 5
    /// Smaller strokes (bounding-box diagonal, points) are handwriting, not shapes.
    static let minimumSize: CGFloat = 16
    /// The stroke is resampled to this many evenly spaced points before fitting.
    static let sampleCount = 96
    /// Line: farthest point from the chord, relative to the chord length.
    static let lineMaxDeviation: CGFloat = 0.06
    /// Line: path length over chord length (rejects zigzags along the chord).
    static let lineMaxPathRatio: CGFloat = 1.12
    /// Closed shape: gap between start and end, relative to the bounding-box diagonal.
    static let closureMaxGap: CGFloat = 0.25
    /// Closed shape: mean distance of the points to the fitted outline, relative to the diagonal.
    static let shapeMaxError: CGFloat = 0.04
    /// An ellipse whose axes are at least this similar is a circle.
    static let circleMinAxisRatio: CGFloat = 0.85
    /// Ramer-Douglas-Peucker tolerance, relative to the diagonal.
    static let simplifyTolerance: CGFloat = 0.05
    /// A polygon vertex turning less than this (degrees) is not a corner.
    static let cornerMinTurnDegrees: CGFloat = 35
    /// Polygon edges shorter than this (relative to the diagonal) are merged into a corner.
    static let minimumEdge: CGFloat = 0.12

    static func recognize(_ points: [CGPoint]) -> RecognizedShape? {
        guard points.count >= minimumPointCount, let box = boundingBox(points) else { return nil }
        let diagonal = hypot(box.width, box.height)
        guard diagonal >= minimumSize, let samples = resample(points, count: sampleCount) else { return nil }
        if let line = line(samples) { return line }
        guard samples[0].distance(to: samples[samples.count - 1]) <= closureMaxGap * diagonal else { return nil }

        let candidates = [roundShape(samples), polygon(samples, diagonal: diagonal)].compactMap { $0 }
        guard let best = candidates.min(by: { error(samples, $0) < error(samples, $1) }),
              error(samples, best) <= shapeMaxError * diagonal else { return nil }
        return best
    }

    // MARK: Line

    private static func line(_ samples: [CGPoint]) -> RecognizedShape? {
        let from = samples[0], to = samples[samples.count - 1]
        let chord = from.distance(to: to)
        guard chord > 0, pathLength(samples) <= lineMaxPathRatio * chord,
              samples.allSatisfy({ distance($0, toSegment: from, to) <= lineMaxDeviation * chord }) else { return nil }
        return .line(from: from, to: to)
    }

    // MARK: Circle / ellipse

    /// Ellipse on the points' principal axes, sized by their extent along each axis.
    private static func roundShape(_ samples: [CGPoint]) -> RecognizedShape? {
        let mean = samples.reduce(CGPoint.zero, +) * (1 / CGFloat(samples.count))
        var xx: CGFloat = 0, yy: CGFloat = 0, xy: CGFloat = 0
        for point in samples {
            let d = point - mean
            xx += d.x * d.x
            yy += d.y * d.y
            xy += d.x * d.y
        }
        let angle = atan2(2 * xy, xx - yy) / 2
        let local = samples.map { ($0 - mean).rotated(by: -angle) }
        guard let extent = boundingBox(local), extent.width > 0, extent.height > 0 else { return nil }
        let center = mean + CGPoint(x: extent.midX, y: extent.midY).rotated(by: angle)
        let radii = CGSize(width: extent.width / 2, height: extent.height / 2)
        if min(radii.width, radii.height) / max(radii.width, radii.height) >= circleMinAxisRatio {
            return .circle(center: center, radius: (radii.width + radii.height) / 2)
        }
        return .ellipse(center: center, radii: radii, angle: angle)
    }

    // MARK: Polygons

    private static func polygon(_ samples: [CGPoint], diagonal: CGFloat) -> RecognizedShape? {
        let corners = cornerVertices(samples, diagonal: diagonal)
        switch corners.count {
        case 3: return .triangle(corners: corners)
        case 4: return rectangle(corners: corners, samples: samples)
        default: return nil
        }
    }

    /// Corners of the closed path: simplified, then flat or crowded vertices removed.
    private static func cornerVertices(_ samples: [CGPoint], diagonal: CGFloat) -> [CGPoint] {
        let tolerance = simplifyTolerance * diagonal
        let far = samples.indices.max { samples[0].distance(to: samples[$0]) < samples[0].distance(to: samples[$1]) } ?? 0
        guard far > 0 else { return [] }
        var vertices = Array(simplify(Array(samples[0...far]), tolerance: tolerance).dropLast())
            + Array(simplify(Array(samples[far...]) + [samples[0]], tolerance: tolerance).dropLast())
        let minimumTurn = cornerMinTurnDegrees * .pi / 180
        while vertices.count > 3 {
            let turns = vertices.indices.map { turn(vertices, at: $0) }
            let flattest = turns.indices.min { turns[$0] < turns[$1] } ?? 0
            if turns[flattest] < minimumTurn {
                vertices.remove(at: flattest)
                continue
            }
            let edges = vertices.indices.map { vertices[$0].distance(to: vertices[($0 + 1) % vertices.count]) }
            let shortest = edges.indices.min { edges[$0] < edges[$1] } ?? 0
            guard edges[shortest] < minimumEdge * diagonal else { break }
            let next = (shortest + 1) % vertices.count
            vertices.remove(at: turns[shortest] < turns[next] ? shortest : next)
        }
        return vertices
    }

    /// Right-angled rectangle aligned with the quadrilateral's mean edge
    /// direction, spanning the points.
    private static func rectangle(corners: [CGPoint], samples: [CGPoint]) -> RecognizedShape? {
        // Directions modulo 90°: averaged as 4θ so that perpendicular edges agree.
        var sum = CGPoint.zero
        for index in corners.indices {
            let edge = corners[(index + 1) % corners.count] - corners[index]
            let length = hypot(edge.x, edge.y)
            let quadrupled = 4 * atan2(edge.y, edge.x)
            sum = sum + CGPoint(x: cos(quadrupled), y: sin(quadrupled)) * length
        }
        let angle = atan2(sum.y, sum.x) / 4
        guard let box = boundingBox(samples.map { $0.rotated(by: -angle) }) else { return nil }
        let local = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                     CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        return .rectangle(corners: local.map { $0.rotated(by: angle) })
    }

    /// Ramer-Douglas-Peucker: keeps the endpoints and the points farther than `tolerance` from the chord.
    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var farthest = 0
        var maxDistance: CGFloat = 0
        for index in 1..<(points.count - 1) {
            let d = distance(points[index], toSegment: first, last)
            if d > maxDistance { maxDistance = d; farthest = index }
        }
        guard maxDistance > tolerance else { return [first, last] }
        return Array(simplify(Array(points[...farthest]), tolerance: tolerance).dropLast())
            + simplify(Array(points[farthest...]), tolerance: tolerance)
    }

    /// Direction change (radians, 0 = straight on) at vertex `index` of a closed polygon.
    private static func turn(_ vertices: [CGPoint], at index: Int) -> CGFloat {
        let previous = vertices[(index + vertices.count - 1) % vertices.count]
        let next = vertices[(index + 1) % vertices.count]
        let a = vertices[index] - previous, b = next - vertices[index]
        let lengths = hypot(a.x, a.y) * hypot(b.x, b.y)
        guard lengths > 0 else { return 0 }
        return acos(max(-1, min(1, (a.x * b.x + a.y * b.y) / lengths)))
    }

    // MARK: Fit error

    /// Mean distance of the samples to the shape's outline.
    static func error(_ samples: [CGPoint], _ shape: RecognizedShape) -> CGFloat {
        let total = samples.reduce(CGFloat(0)) { $0 + distance($1, to: shape) }
        return total / CGFloat(samples.count)
    }

    private static func distance(_ point: CGPoint, to shape: RecognizedShape) -> CGFloat {
        switch shape {
        case let .line(from, to):
            return distance(point, toSegment: from, to)
        case let .circle(center, radius):
            return abs(point.distance(to: center) - radius)
        case let .ellipse(center, radii, angle):
            // Along the ray from the center: |p| · |1 − 1/ρ|, ρ = the ellipse's normalized radius.
            let local = (point - center).rotated(by: -angle)
            let rho = hypot(local.x / radii.width, local.y / radii.height)
            guard rho > 0 else { return min(radii.width, radii.height) }
            return hypot(local.x, local.y) * abs(1 - 1 / rho)
        case let .rectangle(corners), let .triangle(corners):
            return corners.indices.map { distance(point, toSegment: corners[$0], corners[($0 + 1) % corners.count]) }
                .min() ?? 0
        }
    }

    // MARK: Geometry

    private static func distance(_ point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return point.distance(to: a) }
        let t = max(0, min(1, ((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / lengthSquared))
        return point.distance(to: a.interpolated(to: b, t))
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// `count` points evenly spaced along the path (nil for a path of no length).
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint]? {
        let length = pathLength(points)
        guard length > 0 else { return nil }
        let step = length / CGFloat(count - 1)
        var result = [points[0]]
        var travelled: CGFloat = 0
        var target = step
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = a.distance(to: b)
            while segment > 0, travelled + segment >= target, result.count < count - 1 {
                result.append(a.interpolated(to: b, (target - travelled) / segment))
                target += step
            }
            travelled += segment
        }
        return result + [points[points.count - 1]]
    }
}

// MARK: Stroke replacement

extension ShapeRecognizer {
    /// Distance between the replacement stroke's points (drawing points).
    static let outlineSpacing: CGFloat = 4

    /// The stroke redrawn as its recognized shape: same ink (type, color),
    /// transform and pen properties (width etc. of its median-width point);
    /// nil when the stroke is no shape.
    static func snapped(_ stroke: PKStroke) -> PKStroke? {
        let original = Array(stroke.path)
        // `recognize` needs several points, so the median exists.
        guard let shape = recognize(original.map(\.location)) else { return nil }
        let template = original.sorted { $0.size.width < $1.size.width }[original.count / 2]
        let outline = shape.outline(spacing: outlineSpacing)
        let duration = original.last?.timeOffset ?? 0
        let points = outline.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: duration * Double(index) / Double(max(1, outline.count - 1)),
                          size: template.size, opacity: template.opacity, force: template.force,
                          azimuth: template.azimuth, altitude: template.altitude)
        }
        return PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                        transform: stroke.transform, mask: nil)
    }
}

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }

    func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }
    func interpolated(to other: CGPoint, _ t: CGFloat) -> CGPoint { self + (other - self) * t }
    func rotated(by angle: CGFloat) -> CGPoint {
        CGPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }
}
