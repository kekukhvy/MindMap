import CoreGraphics
import Foundation
@testable import MindMap

/// Overlap audit of a laid-out map (WP17): every pair of things that must
/// not overlap — topic frames, boundary outlines (with label tabs), the
/// Tasks panel. Pairs where both sides were placed by the user (floating
/// topics, a dragged panel, a free topic over its own ancestors) are not
/// counted: nothing automatic may move them.
enum LayoutAudit {
    struct Violation: CustomStringConvertible {
        var kind: String
        var a: String
        var b: String
        var description: String { "\(kind): \(a) × \(b)" }
    }

    /// - Parameter panel: the Tasks panel frame (map points), if shown.
    static func violations(map: MindMap, layout: TreeLayout.Result, panel: CGRect? = nil,
                           panelIsFixed: Bool = true) -> [Violation] {
        var result: [Violation] = []
        let frames = layout.frames
        func name(_ id: UUID) -> String { map.node(withID: id)?.text ?? id.uuidString }

        // Who can move relative to whom: the layout only slides auto-laid
        // child subtrees ("blocks") of a common ancestor. Floating topics
        // (and the panel) count as free children of the central topic.
        var path: [UUID: [UUID]] = [:]  // root ... topic
        var isFree: [UUID: Bool] = [:]
        func visit(_ node: Node, prefix: [UUID], free: Bool) {
            path[node.id] = prefix + [node.id]
            isFree[node.id] = free
            guard !node.isCollapsed else { return }
            for child in node.children {
                visit(child, prefix: prefix + [node.id], free: child.manualPosition != nil)
            }
        }
        visit(map.root, prefix: [], free: true)
        for topic in map.floatingTopics { visit(topic.node, prefix: [map.root.id], free: true) }

        /// Neither can move away from the other: one is (inside) a free
        /// subtree lying over its own ancestor, or both are inside different
        /// free children of their lowest common ancestor.
        func bothFixed(_ a: UUID, _ b: UUID) -> Bool {
            guard let pa = path[a], let pb = path[b] else { return true }
            var common = 0
            while common < min(pa.count, pb.count), pa[common] == pb[common] { common += 1 }
            if common == pa.count || common == pb.count {
                // Ancestor / descendant: fixed if a free topic lies between.
                let longer = pa.count > pb.count ? pa : pb
                return longer[common...].contains { isFree[$0] == true }
            }
            return isFree[pa[common]] == true && isFree[pb[common]] == true
        }

        // 1. Topic frames.
        let ids = frames.keys.sorted { $0.uuidString < $1.uuidString }
        for i in ids.indices {
            for j in ids.indices where j > i {
                let a = ids[i], b = ids[j]
                guard let fa = frames[a], let fb = frames[b], !bothFixed(a, b) else { continue }
                if fa.insetBy(dx: 0.5, dy: 0.5).intersects(fb.insetBy(dx: 0.5, dy: 0.5)) {
                    result.append(Violation(kind: "topic", a: name(a), b: name(b)))
                }
            }
        }

        // 2. Boundaries vs topics they do not enclose, label tabs, and
        // boundaries that are neither nested nor disjoint.
        var enclosed: [UUID: Set<UUID>] = [:]
        for boundary in map.boundaries {
            var set = Set<UUID>()
            for member in map.normalizedMembers(of: boundary) {
                guard let node = map.node(withID: member) else { continue }
                set.formUnion(node.allIDs.filter { frames[$0] != nil })
            }
            enclosed[boundary.id] = set
        }
        for boundary in map.boundaries {
            guard let outline = layout.boundaries[boundary.id], let inside = enclosed[boundary.id] else { continue }
            let label = boundary.label ?? "boundary"
            for id in ids where !inside.contains(id) {
                guard let frame = frames[id] else { continue }
                // The outline must cover every enclosed topic: one that cannot move
                // away from `id` (a free topic over it) excuses the overlap.
                if inside.contains(where: { bothFixed($0, id) }) { continue }
                if intersects(outline, frame.insetBy(dx: 0.5, dy: 0.5)) {
                    result.append(Violation(kind: "boundary", a: label, b: name(id)))
                }
            }
            if boundary.hasLabel {
                let tab = outline.labelRect(width: 60, height: LayoutSpacing().boundaryLabelHeight)
                for id in inside {
                    guard let frame = frames[id] else { continue }
                    if tab.insetBy(dx: 0.5, dy: 0.5).intersects(frame) {
                        result.append(Violation(kind: "label", a: label, b: name(id)))
                    }
                }
            }
        }
        for (i, a) in map.boundaries.enumerated() {
            for b in map.boundaries.dropFirst(i + 1) {
                guard let oa = layout.boundaries[a.id], let ob = layout.boundaries[b.id],
                      let ea = enclosed[a.id], let eb = enclosed[b.id] else { continue }
                if ea.isSubset(of: eb) || eb.isSubset(of: ea) { continue }
                if !ea.isDisjoint(with: eb) { continue }
                if polygonsIntersect(oa, ob) {
                    result.append(Violation(kind: "boundary-boundary", a: a.label ?? "?", b: b.label ?? "?"))
                }
            }
        }

        // 3. Tasks panel vs topics of the main tree and boundaries.
        if let panel {
            let rect = panel.insetBy(dx: 0.5, dy: 0.5)
            for id in ids {
                guard let frame = frames[id] else { continue }
                // The panel is a free child of the central topic.
                if panelIsFixed, let p = path[id], p.count == 1 || isFree[p[1]] == true { continue }
                if rect.intersects(frame) { result.append(Violation(kind: "panel", a: "Tasks", b: name(id))) }
            }
            for boundary in map.boundaries {
                guard let outline = layout.boundaries[boundary.id] else { continue }
                if panelIsFixed, map.normalizedMembers(of: boundary).allSatisfy({ path[$0].map { isFree[$0[1]] == true } ?? true }) {
                    continue
                }
                if intersects(outline, rect) {
                    result.append(Violation(kind: "panel-boundary", a: "Tasks", b: boundary.label ?? "?"))
                }
            }
        }
        return result
    }

    // MARK: Geometry

    /// Whether `rect` overlaps the inside of the (rectilinear) outline.
    static func intersects(_ outline: BoundaryOutline, _ rect: CGRect) -> Bool {
        guard outline.bounds.intersects(rect) else { return false }
        if outline.contains(CGPoint(x: rect.midX, y: rect.midY)) { return true }
        let points = outline.polygon
        for (index, a) in points.enumerated() {
            let b = points[(index + 1) % points.count]
            if rect.contains(a) && !onEdge(a, rect) { return true }
            if segmentCrosses(a, b, rect) { return true }
        }
        return false
    }

    static func polygonsIntersect(_ a: BoundaryOutline, _ b: BoundaryOutline) -> Bool {
        guard a.bounds.insetBy(dx: 0.5, dy: 0.5).intersects(b.bounds.insetBy(dx: 0.5, dy: 0.5)) else { return false }
        // Sample the overlap of the bounding boxes on a grid.
        let overlap = a.bounds.intersection(b.bounds).insetBy(dx: 0.5, dy: 0.5)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return false }
        let step: CGFloat = 4
        var y = overlap.minY
        while y <= overlap.maxY {
            var x = overlap.minX
            while x <= overlap.maxX {
                let p = CGPoint(x: x, y: y)
                if a.contains(p) && b.contains(p) && a.distanceToOutline(p) > 0.5 && b.distanceToOutline(p) > 0.5 {
                    return true
                }
                x += step
            }
            y += step
        }
        return false
    }

    private static func onEdge(_ p: CGPoint, _ rect: CGRect) -> Bool {
        abs(p.x - rect.minX) < 0.01 || abs(p.x - rect.maxX) < 0.01 || abs(p.y - rect.minY) < 0.01
            || abs(p.y - rect.maxY) < 0.01
    }

    /// Axis-aligned segment passing through the open rect.
    private static func segmentCrosses(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        if abs(a.y - b.y) < 0.001 {
            guard a.y > rect.minY, a.y < rect.maxY else { return false }
            return max(a.x, b.x) > rect.minX && min(a.x, b.x) < rect.maxX
        }
        if abs(a.x - b.x) < 0.001 {
            guard a.x > rect.minX, a.x < rect.maxX else { return false }
            return max(a.y, b.y) > rect.minY && min(a.y, b.y) < rect.maxY
        }
        return false
    }
}
