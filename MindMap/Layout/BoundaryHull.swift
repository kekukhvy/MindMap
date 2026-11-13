import CoreGraphics
import Foundation

/// Laid-out outline of one boundary (map coordinates): a rectilinear
/// polygon (clockwise on screen, y down) that the view draws with rounded
/// corners. Members next to each other give a plain rectangle; members far
/// apart give the union of their padded subtree areas joined by narrow
/// "necks" routed around other topics (`BoundaryHull`).
struct BoundaryOutline: Equatable {
    /// Outline corners (>= 4, axis-aligned edges).
    var polygon: [CGPoint]
    /// Bounding box of `polygon`.
    var bounds: CGRect
    /// Top-left corner of the label tab (inside the outline).
    var labelOrigin: CGPoint
    /// Width available for the label tab at `labelOrigin`.
    var labelWidth: CGFloat

    var isRectangle: Bool { polygon.count == 4 }

    init(rect: CGRect) {
        polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        bounds = rect
        labelOrigin = rect.origin
        labelWidth = rect.width
    }

    init(polygon: [CGPoint], labelOrigin: CGPoint, labelWidth: CGFloat) {
        self.polygon = polygon
        bounds = BoundaryHull.boundingBox(polygon)
        self.labelOrigin = labelOrigin
        self.labelWidth = labelWidth
    }

    /// Label tab rect (map points).
    func labelRect(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: labelOrigin.x, y: labelOrigin.y, width: min(width, labelWidth), height: height)
    }

    /// Even-odd point-in-polygon test (edges count as inside).
    func contains(_ point: CGPoint) -> Bool {
        if distanceToOutline(point) < 0.01 { return true }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Distance from `point` to the nearest outline edge.
    func distanceToOutline(_ point: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            best = min(best, BoundaryHull.distance(from: point, toSegment: a, b))
        }
        return best
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> BoundaryOutline {
        var copy = self
        copy.polygon = polygon.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        copy.bounds = bounds.offsetBy(dx: dx, dy: dy)
        copy.labelOrigin = CGPoint(x: labelOrigin.x + dx, y: labelOrigin.y + dy)
        return copy
    }
}

/// Pure geometry of a boundary outline from its pieces (one padded rect
/// per member subtree, the label member's one includes the label strip).
///
/// 1. All pieces fit in one box that covers no other topic → that box.
/// 2. Otherwise pieces that touch form groups; groups are joined one pair
///    at a time - by their common box if it is free of other topics, else
///    by a neck (straight or L-shaped strip) placed where it covers the
///    least foreign topic area.
/// 3. Edges closer than `snap` are aligned outwards (no tiny steps), the
///    union of all rects is traced into one outline (holes are filled).
///
/// Every piece lies inside the result by construction.
enum BoundaryHull {
    struct Parameters {
        /// Width of a neck joining distant groups.
        var neck: CGFloat = 22
        /// Edges closer than this are aligned (outwards).
        var snap: CGFloat = 10
        /// Foreign topics count with this margin around them.
        var obstacleMargin: CGFloat = 3
    }

    /// - Parameters:
    ///   - obstacles: foreign topics (never covered if avoidable).
    ///   - boundaries: other boundaries' areas this one should keep out of
    ///     (its box and necks avoid them, at a lower priority than topics).
    ///   - lines: relationship lines, thin rects (necks prefer not to run
    ///     along / across them).
    static func outline(pieces: [CGRect], labelPiece: Int = 0, obstacles: [CGRect], boundaries: [CGRect] = [],
                        lines: [CGRect] = [], parameters: Parameters = Parameters()) -> BoundaryOutline? {
        // Layout runs on every edit: reuse the outline while nothing moved.
        func sorted(_ rects: [CGRect]) -> [CGRect] { rects.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) } }
        let key = CacheKey(pieces: pieces, labelPiece: labelPiece, obstacles: sorted(obstacles),
                           boundaries: sorted(boundaries), lines: sorted(lines))
        if let cached = cache.value(for: key) { return cached }
        let margin = parameters.obstacleMargin
        let all = HullObstacles(topics: key.obstacles.map { $0.insetBy(dx: -margin, dy: -margin) },
                                boundaries: key.boundaries, lines: key.lines)
        let result = computeOutline(pieces: pieces, labelPiece: labelPiece, obstacles: all,
                                    parameters: parameters)
        cache.store(result, for: key)
        return result
    }

    private struct CacheKey: Equatable {
        var pieces: [CGRect]
        var labelPiece: Int
        var obstacles: [CGRect]
        var boundaries: [CGRect]
        var lines: [CGRect]
    }

    /// Last outlines computed (any thread).
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: CacheKey, value: BoundaryOutline?)] = []

        func value(for key: CacheKey) -> BoundaryOutline?? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries.first(where: { $0.key == key }) else { return nil }
            return .some(entry.value)
        }

        func store(_ value: BoundaryOutline?, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            entries.insert((key, value), at: 0)
            if entries.count > 32 { entries.removeLast() }
        }
    }

    private static let cache = Cache()

    private static func computeOutline(pieces: [CGRect], labelPiece: Int, obstacles: HullObstacles,
                                       parameters: Parameters) -> BoundaryOutline? {
        let pieces = pieces.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !pieces.isEmpty else { return nil }
        let labelIndex = pieces.indices.contains(labelPiece) ? labelPiece : 0
        let box = pieces.dropFirst().reduce(pieces[0]) { $0.union($1) }
        if pieces.count == 1 || !obstacles.blocksBox(box) {
            var outline = BoundaryOutline(rect: box)
            let label = pieces[labelIndex]
            outline.labelOrigin = CGPoint(x: label.minX, y: label.minY)
            outline.labelWidth = box.maxX - label.minX
            return outline
        }
        var rects = pieces
        rects += joinGroups(pieces, obstacles: obstacles, parameters: parameters)
        // Aligning must not push an edge onto another topic.
        rects = zip(rects, snapped(rects, distance: parameters.snap)).map { original, aligned in
            obstacles.cost(aligned) > obstacles.cost(original) + 0.5 ? original : aligned
        }
        guard let polygon = unionOutline(rects) else {
            return BoundaryOutline(rect: box)
        }
        let label = rects[labelIndex]
        return BoundaryOutline(polygon: polygon, labelOrigin: CGPoint(x: label.minX, y: label.minY),
                               labelWidth: label.width)
    }

    // MARK: Joining groups

    /// Extra rects (boxes / necks) connecting all touching groups of `pieces`.
    static func joinGroups(_ pieces: [CGRect], obstacles: HullObstacles, parameters: Parameters) -> [CGRect] {
        var groups: [[CGRect]] = []
        for piece in pieces {
            let touching = groups.indices.filter { index in groups[index].contains { touches($0, piece) } }
            var merged = [piece]
            for index in touching.reversed() { merged += groups.remove(at: index) }
            groups.append(merged)
        }
        var extra: [CGRect] = []
        while groups.count > 1 {
            var best: (i: Int, j: Int, rects: [CGRect], score: CGFloat)?
            for i in groups.indices {
                for j in groups.indices where j > i {
                    let candidate = join(groups[i], groups[j], obstacles: obstacles, parameters: parameters)
                    if best == nil || candidate.score < best!.score {
                        best = (i, j, candidate.rects, candidate.score)
                    }
                }
            }
            guard let best else { break }
            extra += best.rects
            let merged = groups[best.i] + groups[best.j] + best.rects
            groups.remove(at: best.j)
            groups[best.i] = merged
        }
        return extra
    }

    /// Cheapest connection of two groups: their box when free of foreign
    /// topics, else a neck between their closest pieces.
    private static func join(_ a: [CGRect], _ b: [CGRect], obstacles: HullObstacles,
                             parameters: Parameters) -> (rects: [CGRect], score: CGFloat) {
        let box = (a + b).dropFirst().reduce((a + b)[0]) { $0.union($1) }
        if !obstacles.blocksBox(box) { return ([box], 0) }
        var best: (rects: [CGRect], score: CGFloat)?
        for ra in a {
            for rb in b {
                let rects = neck(between: ra, and: rb, obstacles: obstacles, width: parameters.neck)
                let overlap = rects.reduce(0) { $0 + obstacles.cost($1) }
                let length = rects.reduce(0) { $0 + max($1.width, $1.height) }
                let score = 1 + overlap * 100 + length
                if best == nil || score < best!.score { best = (rects, score) }
            }
        }
        // A straight neck would cross topics: route one around them.
        if let straight = best, straight.rects.reduce(0, { $0 + obstacles.cost($1) }) > 0,
           let routed = routedNeck(from: a, to: b, obstacles: obstacles, width: parameters.neck * 0.6) {
            let overlap = routed.reduce(0) { $0 + obstacles.cost($1) }
            let length = routed.reduce(0) { $0 + max($1.width, $1.height) }
            let score = 1 + overlap * 100 + length
            if score < straight.score { best = (routed, score) }
        }
        return best ?? ([box], .infinity)
    }

    /// Neck following the shortest grid path (few turns) from group `a` to
    /// group `b` that keeps a strip of `width` clear of foreign topics
    /// (crossing one only if there is no other way). Nil if not found.
    static func routedNeck(from a: [CGRect], to b: [CGRect], obstacles: HullObstacles,
                           width: CGFloat) -> [CGRect]? {
        let all = a + b
        let region = all.dropFirst().reduce(all[0]) { $0.union($1) }.insetBy(dx: -width * 3, dy: -width * 3)
        let cell = max(5, max(region.width, region.height) / 90)
        let columns = Int((region.width / cell).rounded(.up)), rows = Int((region.height / cell).rounded(.up))
        guard columns > 1, rows > 1, columns * rows < 40_000 else { return nil }
        func center(_ index: Int) -> CGPoint {
            CGPoint(x: region.minX + (CGFloat(index % columns) + 0.5) * cell,
                    y: region.minY + (CGFloat(index / columns) + 0.5) * cell)
        }
        // Cells whose neck square would touch a foreign topic (hard: 60 cells
        // extra), another boundary (10) or a relationship line (4).
        var blocked = [CGFloat](repeating: 0, count: columns * rows)
        let weighted = obstacles.topics.map { ($0, CGFloat(60)) } + obstacles.boundaries.map { ($0, CGFloat(10)) }
            + obstacles.lines.map { ($0, CGFloat(4)) }
        for (obstacle, penalty) in weighted {
            let grown = obstacle.insetBy(dx: -width / 2, dy: -width / 2).intersection(region)
            guard !grown.isNull else { continue }
            let c0 = max(0, Int(((grown.minX - region.minX) / cell - 0.5).rounded(.up)))
            let c1 = min(columns - 1, Int(((grown.maxX - region.minX) / cell - 0.5).rounded(.down)))
            let r0 = max(0, Int(((grown.minY - region.minY) / cell - 0.5).rounded(.up)))
            let r1 = min(rows - 1, Int(((grown.maxY - region.minY) / cell - 0.5).rounded(.down)))
            guard c0 <= c1, r0 <= r1 else { continue }
            for row in r0...r1 {
                for column in c0...c1 { blocked[row * columns + column] = max(blocked[row * columns + column], penalty) }
            }
        }
        func inside(_ rects: [CGRect], _ index: Int) -> Bool {
            let point = center(index)
            return rects.contains { $0.insetBy(dx: 1, dy: 1).contains(point) }
        }
        // Dijkstra over (cell, heading); turns and blocked cells cost extra.
        let directions = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        let stateCount = columns * rows * 4
        var distance = [CGFloat](repeating: .infinity, count: stateCount)
        var previous = [Int](repeating: -1, count: stateCount)
        var heap = MinHeap()
        for index in 0..<(columns * rows) where inside(a, index) {
            for heading in 0..<4 {
                distance[index * 4 + heading] = 0
                heap.push(0, index * 4 + heading)
            }
        }
        var goal: Int?
        while let (cost, state) = heap.pop() {
            guard cost <= distance[state] else { continue }
            let index = state / 4, heading = state % 4
            if inside(b, index) {
                goal = state
                break
            }
            for (newHeading, step) in directions.enumerated() {
                let column = index % columns + step.0, row = index / columns + step.1
                guard column >= 0, row >= 0, column < columns, row < rows else { continue }
                let next = row * columns + column
                var value = cost + cell
                if newHeading != heading { value += cell * 3 }
                if blocked[next] > 0 && !inside(a, next) && !inside(b, next) { value += cell * blocked[next] }
                let nextState = next * 4 + newHeading
                if value < distance[nextState] {
                    distance[nextState] = value
                    previous[nextState] = state
                    heap.push(value, nextState)
                }
            }
        }
        guard var state = goal else { return nil }
        var path: [CGPoint] = []
        while state >= 0 {
            path.append(center(state / 4))
            state = previous[state]
        }
        path.reverse()
        // Straight runs -> strips of `width` around them.
        var rects: [CGRect] = []
        var runStart = path[0]
        for i in path.indices.dropFirst() {
            let isLast = i == path.count - 1
            let turns = !isLast && ((path[i + 1].x - path[i].x) != (path[i].x - path[i - 1].x)
                                    || (path[i + 1].y - path[i].y) != (path[i].y - path[i - 1].y))
            if turns || isLast {
                rects.append(MarqueeSelection.rect(from: runStart, to: path[i]).insetBy(dx: -width / 2, dy: -width / 2))
                runStart = path[i]
            }
        }
        if rects.isEmpty, let point = path.first {
            rects.append(CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width))
        }
        return rects
    }

    /// Small binary min-heap of (priority, value) for `routedNeck`.
    private struct MinHeap {
        private var items: [(CGFloat, Int)] = []

        mutating func push(_ priority: CGFloat, _ value: Int) {
            items.append((priority, value))
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].0 < items[parent].0 else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> (CGFloat, Int)? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].0 < items[smallest].0 { smallest = left }
                if right < items.count, items[right].0 < items[smallest].0 { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
            return top
        }
    }

    /// Strip(s) from `a` to `b` (overlapping both by 1 pt so they connect).
    /// A straight neck may stick out sideways (keeping `minOverlap` with
    /// both) and get narrower to pass through the gap next to a column of
    /// topics, e.g. the connector space between a parent and its children.
    static func neck(between a: CGRect, and b: CGRect, obstacles: [CGRect], width: CGFloat) -> [CGRect] {
        neck(between: a, and: b, obstacles: HullObstacles(topics: obstacles), width: width)
    }

    static func neck(between a: CGRect, and b: CGRect, obstacles: HullObstacles, width: CGFloat) -> [CGRect] {
        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        if overlapX > 0 {
            let (upper, lower) = a.midY <= b.midY ? (a, b) : (b, a)
            let y0 = upper.maxY - 1, height = max(lower.minY + 1 - y0, 0)
            return [bestStrip(lo: max(a.minX, b.minX), hi: min(a.maxX, b.maxX), width: width, obstacles: obstacles) {
                CGRect(x: $0, y: y0, width: $1, height: height)
            }]
        }
        if overlapY > 0 {
            let (left, right) = a.midX <= b.midX ? (a, b) : (b, a)
            let x0 = left.maxX - 1, length = max(right.minX + 1 - x0, 0)
            return [bestStrip(lo: max(a.minY, b.minY), hi: min(a.maxY, b.maxY), width: width, obstacles: obstacles) {
                CGRect(x: x0, y: $0, width: length, height: $1)
            }]
        }
        // Diagonal: L-shaped (horizontal leg from one, vertical into the other).
        let first = lShape(from: a, to: b, width: width)
        let second = lShape(from: b, to: a, width: width)
        let firstCost = first.reduce(0) { $0 + obstacles.cost($1) }
        let secondCost = second.reduce(0) { $0 + obstacles.cost($1) }
        return firstCost <= secondCost ? first : second
    }

    /// Strip across the common range [lo, hi] of two pieces: least foreign
    /// area, then widest, then closest to an outer edge (straight sides).
    private static func bestStrip(lo: CGFloat, hi: CGFloat, width: CGFloat, obstacles: HullObstacles,
                                  rect: (_ start: CGFloat, _ width: CGFloat) -> CGRect) -> CGRect {
        let minOverlap = min(6, hi - lo)
        var best: (rect: CGRect, cost: CGFloat, width: CGFloat, edge: CGFloat)?
        for w in [width, width * 0.75, width * 0.55] where w > 0 {
            let first = lo - w + minOverlap, last = max(first, hi - minOverlap)
            var start = first
            while true {
                let candidate = rect(start, w)
                let value = obstacles.cost(candidate)
                let edge = min(start - first, last - start)
                let better: Bool
                if let best {
                    if abs(value - best.cost) > 0.01 { better = value < best.cost }
                    else if abs(w - best.width) > 0.01 { better = w > best.width }
                    else { better = edge < best.edge }
                } else {
                    better = true
                }
                if better { best = (candidate, value, w, edge) }
                if start >= last { break }
                start = min(start + 2, last)
            }
        }
        return best?.rect ?? rect(lo, min(width, hi - lo))
    }

    /// Horizontal strip leaving `a` towards `b`, then vertical strip into `b`.
    private static func lShape(from a: CGRect, to b: CGRect, width: CGFloat) -> [CGRect] {
        let w = min(width, a.height, b.width)
        let toRight = b.midX > a.midX, down = b.midY > a.midY
        let legY = down ? a.maxY - w : a.minY
        let legX = toRight ? b.minX : b.maxX - w
        let horizontal = CGRect(x: toRight ? a.maxX - 1 : legX, y: legY,
                                width: toRight ? legX + w - (a.maxX - 1) : a.minX + 1 - legX, height: w)
        let vertical = CGRect(x: legX, y: down ? legY : b.maxY - 1,
                              width: w, height: down ? b.minY + 1 - legY : legY + w - (b.maxY - 1))
        return [horizontal, vertical].map(\.standardized)
    }

    /// Everything a boundary outline keeps clear of, by priority.
    struct HullObstacles {
        /// Foreign topics (with margin): worst.
        var topics: [CGRect]
        /// Other boundaries' areas: avoided unless that costs a topic.
        var boundaries: [CGRect] = []
        /// Relationship lines (thin rects): mildly avoided by necks.
        var lines: [CGRect] = []

        /// Weighted covered area (topics 1, boundaries 0.3, lines 0.15).
        func cost(_ rect: CGRect) -> CGFloat {
            BoundaryHull.cost(rect, topics) + 0.3 * BoundaryHull.cost(rect, boundaries)
                + 0.15 * BoundaryHull.cost(rect, lines)
        }

        /// A plain box is not usable when it covers a topic or another
        /// boundary (lines may cross a box: they cross its edge anyway).
        func blocksBox(_ rect: CGRect) -> Bool {
            BoundaryHull.cost(rect, topics) > 0 || BoundaryHull.cost(rect, boundaries) > 0
        }
    }

    /// Foreign topic area covered by `rect`.
    static func cost(_ rect: CGRect, _ obstacles: [CGRect]) -> CGFloat {
        obstacles.reduce(0) { total, obstacle in
            let overlap = rect.intersection(obstacle)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
    }

    private static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.insetBy(dx: -0.5, dy: -0.5).intersection(b)
        return !overlap.isNull && (overlap.width > 0.5 || overlap.height > 0.5)
            && overlap.width >= 0 && overlap.height >= 0
    }

    // MARK: Snapping

    /// Aligns rect edges closer than `distance` to the outermost of them.
    static func snapped(_ rects: [CGRect], distance: CGFloat) -> [CGRect] {
        let xs = clusters(rects.flatMap { [$0.minX, $0.maxX] }, distance: distance)
        let ys = clusters(rects.flatMap { [$0.minY, $0.maxY] }, distance: distance)
        return rects.map { rect in
            let minX = xs.first { $0.contains(rect.minX) }?.lowerBound ?? rect.minX
            let maxX = xs.first { $0.contains(rect.maxX) }?.upperBound ?? rect.maxX
            let minY = ys.first { $0.contains(rect.minY) }?.lowerBound ?? rect.minY
            let maxY = ys.first { $0.contains(rect.maxY) }?.upperBound ?? rect.maxY
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private static func clusters(_ values: [CGFloat], distance: CGFloat) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        for value in values.sorted() {
            // Chains stay short: a cluster never spans more than 2 x distance.
            if let last = result.last, value - last.upperBound <= distance, value - last.lowerBound <= distance * 2 {
                result[result.count - 1] = last.lowerBound...value
            } else {
                result.append(value...value)
            }
        }
        return result
    }

    // MARK: Union outline

    /// Outer outline of the union of `rects` (largest outer loop; holes are
    /// ignored = filled), collinear points removed. Clockwise on screen.
    static func unionOutline(_ rects: [CGRect]) -> [CGPoint]? {
        let xs = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set(rects.flatMap { [$0.minY, $0.maxY] })).sorted()
        guard xs.count >= 2, ys.count >= 2 else { return nil }
        let columns = xs.count - 1, rows = ys.count - 1
        var covered = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            let cy = (ys[row] + ys[row + 1]) / 2
            for column in 0..<columns {
                let cx = (xs[column] + xs[column + 1]) / 2
                covered[row * columns + column] = rects.contains { $0.contains(CGPoint(x: cx, y: cy)) }
            }
        }
        func isCovered(_ column: Int, _ row: Int) -> Bool {
            column >= 0 && row >= 0 && column < columns && row < rows && covered[row * columns + column]
        }
        // Directed boundary edges between grid points (column, row): interior on the right.
        struct GridPoint: Hashable { var x: Int; var y: Int }
        var outgoing: [GridPoint: [GridPoint]] = [:]
        var edgeCount = 0
        func add(_ from: GridPoint, _ to: GridPoint) {
            outgoing[from, default: []].append(to)
            edgeCount += 1
        }
        for row in 0..<rows {
            for column in 0..<columns where isCovered(column, row) {
                if !isCovered(column, row - 1) { add(GridPoint(x: column, y: row), GridPoint(x: column + 1, y: row)) }
                if !isCovered(column + 1, row) {
                    add(GridPoint(x: column + 1, y: row), GridPoint(x: column + 1, y: row + 1))
                }
                if !isCovered(column, row + 1) {
                    add(GridPoint(x: column + 1, y: row + 1), GridPoint(x: column, y: row + 1))
                }
                if !isCovered(column - 1, row) { add(GridPoint(x: column, y: row + 1), GridPoint(x: column, y: row)) }
            }
        }
        var loops: [[GridPoint]] = []
        while let start = outgoing.first(where: { !$0.value.isEmpty })?.key {
            var loop: [GridPoint] = [start]
            var previous = start
            var current = outgoing[start]!.removeFirst()
            var guardCount = 0
            while current != start, guardCount <= edgeCount {
                guardCount += 1
                loop.append(current)
                guard var options = outgoing[current], !options.isEmpty else { break }
                // Prefer turning right (keeps diagonally touching areas apart).
                let dx = current.x - previous.x, dy = current.y - previous.y
                func rank(_ next: GridPoint) -> Int {
                    let nx = next.x - current.x, ny = next.y - current.y
                    if nx == -dy && ny == dx { return 0 }
                    if nx == dx && ny == dy { return 1 }
                    return 2
                }
                options.sort { rank($0) < rank($1) }
                let next = options.removeFirst()
                outgoing[current] = options
                previous = current
                current = next
            }
            loops.append(loop)
        }
        let polygons = loops.map { loop in loop.map { CGPoint(x: xs[$0.x], y: ys[$0.y]) } }
        guard let outer = polygons.max(by: { signedArea($0) < signedArea($1) }), signedArea(outer) > 0 else {
            return nil
        }
        return simplified(outer)
    }

    /// Shoelace area; positive for clockwise-on-screen (y down) loops.
    static func signedArea(_ polygon: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Drops points on a straight line between their neighbours.
    static func simplified(_ polygon: [CGPoint]) -> [CGPoint] {
        var points = polygon
        var changed = true
        while changed, points.count > 4 {
            changed = false
            for i in points.indices {
                let a = points[(i + points.count - 1) % points.count], b = points[i], c = points[(i + 1) % points.count]
                let collinear = (abs(a.x - b.x) < 0.001 && abs(b.x - c.x) < 0.001)
                    || (abs(a.y - b.y) < 0.001 && abs(b.y - c.y) < 0.001)
                if collinear {
                    points.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return points
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Rounded path

    /// Outline with rounded corners (radius clamped to half the shorter
    /// adjacent edge), transformed by `transform` (e.g. map -> screen).
    static func roundedPath(_ polygon: [CGPoint], radius: CGFloat,
                            transform: (CGPoint) -> CGPoint = { $0 }) -> CGPath {
        let points = polygon.map(transform)
        let path = CGMutablePath()
        guard points.count >= 3 else { return path }
        let count = points.count
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[count - 1], points[0]))
        for i in 0..<count {
            let corner = points[i], next = points[(i + 1) % count], previous = points[(i + count - 1) % count]
            let shorter = min(hypot(corner.x - previous.x, corner.y - previous.y),
                              hypot(next.x - corner.x, next.y - corner.y))
            path.addArc(tangent1End: corner, tangent2End: next, radius: max(0, min(radius, shorter / 2)))
        }
        path.closeSubpath()
        return path
    }
}
