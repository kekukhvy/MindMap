import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import MindMap

/// Notes-style "draw a shape and hold": which hand-drawn strokes become
/// which clean shapes, and which stay as drawn.
struct ShapeRecognizerTests {
    private static let tolerance: CGFloat = 6

    /// Deterministic hand tremor in [-1, 1].
    private static func wobble(_ i: Int) -> CGFloat {
        let x = CGFloat(i)
        return 0.6 * sin(x * 1.7) + 0.4 * cos(x * 0.53)
    }

    private static func isClose(_ a: CGPoint, _ b: CGPoint, within limit: CGFloat = tolerance) -> Bool {
        hypot(a.x - b.x, a.y - b.y) <= limit
    }

    /// A hand-drawn closed ellipse: starts at `start` radians, overshoots a
    /// little, radius trembling by `noise` (relative).
    private static func roundStroke(center: CGPoint, radii: CGSize, angle: CGFloat = 0, start: CGFloat = 0.3,
                                    noise: CGFloat = 0.03, count: Int = 140) -> [CGPoint] {
        (0...count).map { i in
            let t = start + 2.08 * .pi * CGFloat(i) / CGFloat(count)
            let scale = 1 + noise * wobble(i)
            let x = radii.width * scale * cos(t), y = radii.height * scale * sin(t)
            return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
    }

    /// A hand-drawn polygon through `corners` back to the start, `wobble`
    /// points off the edges, starting a third of the way along the first edge.
    private static func polygonStroke(_ corners: [CGPoint], wobble amount: CGFloat = 2, perEdge: Int = 30) -> [CGPoint] {
        var points: [CGPoint] = []
        let ring = corners + [corners[0], corners[1]]
        for edge in 0...corners.count {
            let a = ring[edge], b = ring[edge + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            let range = edge == 0 ? (perEdge / 3)...perEdge : edge == corners.count ? 1...(perEdge / 3) : 1...perEdge
            for step in range {
                let t = CGFloat(step) / CGFloat(perEdge)
                let off = amount * wobble(points.count)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + normal.x * off, y: a.y + (b.y - a.y) * t + normal.y * off))
            }
        }
        return points
    }

    private static func rotated(_ points: [CGPoint], by angle: CGFloat, around center: CGPoint) -> [CGPoint] {
        points.map { p in
            let d = CGPoint(x: p.x - center.x, y: p.y - center.y)
            return CGPoint(x: center.x + d.x * cos(angle) - d.y * sin(angle), y: center.y + d.x * sin(angle) + d.y * cos(angle))
        }
    }

    /// Every expected corner has a recognized corner nearby.
    private static func matches(_ corners: [CGPoint], _ expected: [CGPoint]) -> Bool {
        corners.count == expected.count && expected.allSatisfy { e in corners.contains { isClose($0, e) } }
    }

    @Test func noisyCircleBecomesACircle() throws {
        let shape = ShapeRecognizer.recognize(Self.roundStroke(center: CGPoint(x: 300, y: 200),
                                                               radii: CGSize(width: 80, height: 80)))
        guard case let .circle(center, radius) = shape else { Issue.record("got \(String(describing: shape))"); return }
        #expect(Self.isClose(center, CGPoint(x: 300, y: 200)))
        #expect(abs(radius - 80) < Self.tolerance)
        // Shakier, and the Pencil resting at the end.
        var held = Self.roundStroke(center: CGPoint(x: 300, y: 200), radii: CGSize(width: 50, height: 50), noise: 0.06)
        held += Array(repeating: held[held.count - 1], count: 40)
        guard case .circle = ShapeRecognizer.recognize(held) else { Issue.record("shaky circle"); return }
    }

    @Test func rotatedEllipseBecomesAnEllipse() throws {
        let shape = ShapeRecognizer.recognize(Self.roundStroke(center: CGPoint(x: 400, y: 300),
                                                               radii: CGSize(width: 140, height: 60), angle: 0.4))
        guard case let .ellipse(center, radii, angle) = shape else { Issue.record("got \(String(describing: shape))"); return }
        #expect(Self.isClose(center, CGPoint(x: 400, y: 300)))
        #expect(abs(radii.width - 140) < Self.tolerance && abs(radii.height - 60) < Self.tolerance)
        let difference = (angle - 0.4).truncatingRemainder(dividingBy: .pi)
        #expect(min(abs(difference), .pi - abs(difference)) < 0.05)
    }

    @Test func wobblyRectangleBecomesARectangle() throws {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 320, y: 100), CGPoint(x: 320, y: 220), CGPoint(x: 100, y: 220)]
        let shape = ShapeRecognizer.recognize(Self.polygonStroke(corners))
        guard case let .rectangle(found) = shape else { Issue.record("got \(String(describing: shape))"); return }
        #expect(Self.matches(found, corners))

        // A square, and the Pencil resting at the end (many points on the spot).
        let square = [CGPoint(x: 100, y: 100), CGPoint(x: 260, y: 100), CGPoint(x: 260, y: 260), CGPoint(x: 100, y: 260)]
        var held = Self.polygonStroke(square, wobble: 3)
        held += Array(repeating: held[held.count - 1], count: 40)
        guard case let .rectangle(squareFound) = ShapeRecognizer.recognize(held) else { Issue.record("square"); return }
        #expect(Self.matches(squareFound, square))
    }

    @Test func rotatedRectangleBecomesARotatedRectangle() throws {
        let center = CGPoint(x: 210, y: 160)
        let corners = Self.rotated([CGPoint(x: 100, y: 100), CGPoint(x: 320, y: 100), CGPoint(x: 320, y: 220),
                                    CGPoint(x: 100, y: 220)], by: .pi / 6, around: center)
        let shape = ShapeRecognizer.recognize(Self.polygonStroke(corners))
        guard case let .rectangle(found) = shape else { Issue.record("got \(String(describing: shape))"); return }
        #expect(Self.matches(found, corners))
        // Right angles.
        let a = CGPoint(x: found[1].x - found[0].x, y: found[1].y - found[0].y)
        let b = CGPoint(x: found[2].x - found[1].x, y: found[2].y - found[1].y)
        #expect(abs(a.x * b.x + a.y * b.y) < 0.001 * hypot(a.x, a.y) * hypot(b.x, b.y))
    }

    @Test func wobblyTriangleBecomesATriangle() throws {
        let corners = [CGPoint(x: 200, y: 80), CGPoint(x: 330, y: 300), CGPoint(x: 70, y: 290)]
        let shape = ShapeRecognizer.recognize(Self.polygonStroke(corners))
        guard case let .triangle(found) = shape else { Issue.record("got \(String(describing: shape))"); return }
        #expect(Self.matches(found, corners))
    }

    @Test func wobblyLineBecomesAStraightLine() throws {
        let points = (0...60).map { i in CGPoint(x: 50 + CGFloat(i) * 5, y: 120 + CGFloat(i) * 2 + 3 * Self.wobble(i)) }
        let shape = ShapeRecognizer.recognize(points)
        guard case let .line(from, to) = shape else { Issue.record("got \(String(describing: shape))"); return }
        #expect(from == points[0] && to == points[points.count - 1])
    }

    @Test func zigzagScribbleAndOpenCurveStayAsDrawn() {
        let zigzag = (0...40).map { i in CGPoint(x: 50 + CGFloat(i) * 6, y: i.isMultiple(of: 2) ? 100 : 130) }
        let figureEight = (0...160).map { i -> CGPoint in
            let t = 2 * CGFloat.pi * CGFloat(i) / 160
            return CGPoint(x: 300 + 120 * sin(t), y: 200 + 60 * sin(2 * t))
        }
        let star = (0..<5).map { i -> CGPoint in
            let t = -CGFloat.pi / 2 + CGFloat(i) * 4 * .pi / 5
            return CGPoint(x: 200 + 100 * cos(t), y: 200 + 100 * sin(t))
        }
        let openArc = (0...90).map { i -> CGPoint in
            let t = 1.5 * CGFloat.pi * CGFloat(i) / 90
            return CGPoint(x: 200 + 80 * cos(t), y: 200 + 80 * sin(t))
        }
        let handwriting = (0...200).map { i -> CGPoint in
            let t = CGFloat(i) / 200 * 6 * .pi
            return CGPoint(x: 80 + CGFloat(i) * 1.5 + 25 * cos(t), y: 150 - 25 * sin(t))
        }
        #expect(ShapeRecognizer.recognize(zigzag) == nil)
        #expect(ShapeRecognizer.recognize(figureEight) == nil)
        #expect(ShapeRecognizer.recognize(Self.polygonStroke(star, wobble: 1, perEdge: 20)) == nil)
        #expect(ShapeRecognizer.recognize(openArc) == nil)
        #expect(ShapeRecognizer.recognize(handwriting) == nil)
        // A dot is no shape.
        #expect(ShapeRecognizer.recognize((0...10).map { CGPoint(x: 100 + CGFloat($0) * 0.3, y: 100) }) == nil)
    }

    @Test func snappedStrokeKeepsInkWidthAndLiesOnTheShape() throws {
        let points = Self.roundStroke(center: CGPoint(x: 300, y: 200), radii: CGSize(width: 80, height: 80))
        let stroke = DebugDrawing.stroke(points, color: .red, width: 7, ink: .marker)
        let snapped = try #require(ShapeRecognizer.snapped(stroke))
        #expect(snapped.ink.inkType == .marker)
        #expect(snapped.ink.color == stroke.ink.color)
        #expect(snapped.transform == stroke.transform)
        guard case let .circle(center, radius) = ShapeRecognizer.recognize(points) else {
            Issue.record("not a circle"); return
        }
        let path = Array(snapped.path)
        #expect(path.count > 20)
        #expect(path.allSatisfy { $0.size.width == 7 })
        #expect(path.allSatisfy { abs(hypot($0.location.x - center.x, $0.location.y - center.y) - radius) < 0.01 })
        // Handwriting is left alone.
        let word = (0...200).map { i -> CGPoint in
            let t = CGFloat(i) / 200 * 6 * .pi
            return CGPoint(x: 80 + CGFloat(i) * 1.5 + 25 * cos(t), y: 150 - 25 * sin(t))
        }
        #expect(ShapeRecognizer.snapped(DebugDrawing.stroke(word, color: .black)) == nil)
    }
}
