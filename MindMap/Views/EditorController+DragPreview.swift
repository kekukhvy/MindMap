import CoreGraphics
import Foundation

/// Live branch line while a topic is dragged (XMind): it follows the
/// dragged topic from its prospective parent - the hovered drop target
/// (child drop), the target's parent (sibling drop), or the current parent
/// (free move / no target). The topic's normal line is hidden meanwhile.
extension EditorController {
    /// Parent the dragged topic would get if dropped now (nil: floating root).
    func prospectiveParent(for drag: NodeDrag) -> UUID? {
        prospectiveParent(for: drag, of: drag.id)
    }

    /// Parent topic `id` (one of the dragged topics) would get if dropped now.
    func prospectiveParent(for drag: NodeDrag, of id: UUID) -> UUID? {
        if let target = drag.targetID {
            return drag.placement == .child ? target : model.map.parentID(of: target)
        }
        return model.map.parentID(of: id)
    }

    /// Where the dragged topic is drawn now (map coordinates).
    func ghostFrame(for drag: NodeDrag) -> CGRect? {
        ghostFrame(for: drag, of: drag.id)
    }

    func ghostFrame(for drag: NodeDrag, of id: UUID) -> CGRect? {
        scene.layout.frames[id]?.offsetBy(dx: drag.translation.width / viewport.scale,
                                          dy: drag.translation.height / viewport.scale)
    }

    /// The dragged topic's live line (map coordinates), styled like its own line.
    var dragConnector: MapScene.StyledConnector? {
        guard let drag else { return nil }
        return dragConnector(for: drag, of: drag.id)
    }

    /// Live lines of every moving topic (a multi-selection drags them all).
    var dragConnectors: [MapScene.StyledConnector] {
        guard let drag else { return [] }
        let ids = drag.movingIDs.isEmpty ? [drag.id] : drag.movingIDs
        return ids.compactMap { dragConnector(for: drag, of: $0) }
    }

    private func dragConnector(for drag: NodeDrag, of id: UUID) -> MapScene.StyledConnector? {
        guard drag.translation != .zero, let parentID = prospectiveParent(for: drag, of: id),
              parentID != id, let parent = scene.layout.frames[parentID],
              let ghost = ghostFrame(for: drag, of: id) else { return nil }
        let original = scene.connectors.first { $0.childID == id }
        var geometry = EditorController.liveGeometry(from: parent, to: ghost)
        geometry.style = original?.geometry.style ?? .curved
        geometry.startWidth = original?.geometry.startWidth ?? MapScene.defaultLineWidth
        geometry.endWidth = geometry.startWidth
        geometry.dash = original?.geometry.dash ?? .solid
        let color = original?.colorHex ?? scene.nodes[id]?.appearance.colorHex ?? ColorTheme.rootColorHex
        return MapScene.StyledConnector(childID: id, geometry: geometry, colorHex: color)
    }

    /// Branch lines to draw: the dragged topics' own lines are replaced by
    /// `dragConnectors` while they move.
    var drawnConnectors: [MapScene.StyledConnector] {
        guard let drag, drag.translation != .zero else { return scene.connectors + fadingConnectors }
        let moving = Set(drag.movingIDs + [drag.id])
        return scene.connectors.filter { !moving.contains($0.childID) }
    }

    /// Parent edge -> ghost edge: sideways when the ghost is beside the
    /// parent, else vertical (above / below), like a freely placed topic.
    static func liveGeometry(from parent: CGRect, to ghost: CGRect) -> ConnectorGeometry {
        let start: CGPoint, end: CGPoint, axis: ConnectorAxis
        if ghost.minX >= parent.maxX || ghost.maxX <= parent.minX {
            let right = ghost.midX > parent.midX
            axis = .horizontal
            start = CGPoint(x: right ? parent.maxX : parent.minX, y: parent.midY)
            end = CGPoint(x: right ? ghost.minX : ghost.maxX, y: ghost.midY)
        } else {
            let below = ghost.midY > parent.midY
            axis = .vertical
            start = CGPoint(x: parent.midX, y: below ? parent.maxY : parent.minY)
            end = CGPoint(x: ghost.midX, y: below ? ghost.minY : ghost.maxY)
        }
        return ConnectorGeometry(start: start, end: end, startAxis: axis, endAxis: axis, style: .curved,
                                 startWidth: MapScene.defaultLineWidth, endWidth: MapScene.defaultLineWidth,
                                 dash: .solid)
    }
}
