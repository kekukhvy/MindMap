import CoreGraphics
import Foundation

/// Edge of a node where its collapse badge sits (towards its children).
enum BadgeEdge: Equatable {
    case leading, trailing, bottom
}

/// Everything the canvas draws for one map state: appearances, measured
/// layout and styled connectors (map coordinates). Built off the view tree.
struct MapScene {
    struct NodeInfo {
        var text: String
        var appearance: NodeAppearance
        var level: Int
        /// Number of hidden descendants when collapsed (0 = no badge).
        var hiddenCount: Int
        var hasChildren: Bool
        var isCollapsed: Bool
        /// Root of the main tree or of a floating topic.
        var isTreeRoot: Bool
        var badgeEdge: BadgeEdge
        /// Icons at the trailing edge (content opens in a sheet / window).
        var attachments: [AttachmentSummary] = []
        /// Link icon before the title (web URL / topic link, maybe broken).
        var link: LinkSummary?
        /// Task checkbox / priority / due chip (nil = plain topic).
        var task: TaskSummary?
    }

    struct StyledConnector: Identifiable {
        var id: UUID { childID }
        var childID: UUID
        var geometry: ConnectorGeometry
        var colorHex: String
    }

    var nodes: [UUID: NodeInfo] = [:]
    /// Draw order (pre-order per tree).
    var order: [UUID] = []
    var layout: TreeLayout.Result
    var connectors: [StyledConnector] = []
    var navigator: SelectionNavigator
    /// Effective branch colors (for boundaries etc.).
    var colors: [UUID: String]
    /// End axis of each visible node's incoming connector.
    var incomingAxis: [UUID: ConnectorAxis] = [:]

    /// Axis along which `id` and its siblings are stacked (nil for roots):
    /// side-entered children stack vertically, top-entered ones horizontally.
    func siblingAxis(of id: UUID) -> ConnectorAxis? {
        incomingAxis[id].map { $0 == .horizontal ? .vertical : .horizontal }
    }

    /// - Parameter editing: node being edited and its draft text (sizes follow the draft).
    /// - Parameter now: "today" for due chips (overdue / Today / Tomorrow).
    /// - Parameter hidesAttachment: attachments without an icon (empty notes).
    /// - Parameter fixedObstacles: user-placed areas topics keep clear of
    ///   (a dragged Tasks panel), map coordinates.
    static func build(map: MindMap, measurer: NodeMeasurer, editing: (id: UUID, text: String)?,
                      now: Date = Date(), fixedObstacles: [CGRect] = [],
                      hidesAttachment: (Attachment) -> Bool = { _ in false }) -> MapScene {
        let colors = ColorResolver.effectiveColors(in: map)
        var infos: [UUID: NodeInfo] = [:]
        var order: [UUID] = []
        func visit(_ node: Node, level: Int, isTreeRoot: Bool) {
            let appearance = NodeAppearance.resolve(shape: node.shape, border: node.borderStyle, level: level,
                                                    colorHex: colors[node.id] ?? ColorTheme.rootColorHex)
            let text = editing?.id == node.id ? editing!.text : node.text
            infos[node.id] = NodeInfo(text: text, appearance: appearance, level: level,
                                      hiddenCount: node.isCollapsed ? node.subtreeCount - 1 : 0,
                                      hasChildren: !node.children.isEmpty, isCollapsed: node.isCollapsed,
                                      isTreeRoot: isTreeRoot, badgeEdge: .trailing,
                                      attachments: node.attachments.filter { !hidesAttachment($0) }
                                          .map(AttachmentSummary.init),
                                      link: node.link == nil ? nil : LinkSummary(of: node, in: map),
                                      task: node.task.map {
                                          TaskSummary($0, now: now, measurer: measurer, fontSize: appearance.fontSize)
                                      })
            order.append(node.id)
            guard !node.isCollapsed else { return }
            for child in node.children { visit(child, level: level + 1, isTreeRoot: false) }
        }
        visit(map.root, level: 0, isTreeRoot: true)
        for topic in map.floatingTopics { visit(topic.node, level: 1, isTreeRoot: true) }

        let layout = TreeLayout().layout(map, fixedObstacles: fixedObstacles) { id in
            guard let info = infos[id] else { return CGSize(width: 40, height: 20) }
            return measurer.nodeSize(text: info.text, appearance: info.appearance, attachments: info.attachments,
                                     hasLink: info.link != nil, task: info.task)
        }
        let navigator = SelectionNavigator(layout: layout)
        for id in order {
            switch navigator.directionToParent(of: id) {
            case .right: infos[id]?.badgeEdge = .leading
            case .up: infos[id]?.badgeEdge = .bottom
            default: break
            }
        }
        // Expanded topics: the toggle sits where their branch lines leave.
        var firstOutgoing: [UUID: Connector] = [:]
        for connector in layout.connectors where firstOutgoing[connector.parentID] == nil {
            firstOutgoing[connector.parentID] = connector
        }
        for (id, connector) in firstOutgoing {
            guard let frame = layout.frames[id] else { continue }
            if connector.startAxis == .vertical {
                infos[id]?.badgeEdge = .bottom
            } else {
                infos[id]?.badgeEdge = connector.start.x <= frame.midX ? .leading : .trailing
            }
        }
        var scene = MapScene(nodes: infos, order: order, layout: layout, navigator: navigator, colors: colors)
        scene.connectors = layout.connectors.map { scene.styled($0) }
        for connector in layout.connectors { scene.incomingAxis[connector.childID] = connector.endAxis }
        return scene
    }

    /// Default branch line width (thin, XMind pastel look; not tapered).
    static let defaultLineWidth: CGFloat = 1.25

    /// Resolves widths, moves endpoints onto underlines and gives central
    /// topic edges their XMind quarter curves.
    private func styled(_ connector: Connector) -> StyledConnector {
        let parent = nodes[connector.parentID]
        let child = nodes[connector.childID]
        var start = connector.start, end = connector.end
        var startAxis = connector.startAxis
        let inset = NodeAppearance.underlineWidth / 2
        if parent?.appearance.shape == .underline, connector.startAxis == .horizontal,
           let frame = layout.frames[connector.parentID] {
            start.y = frame.maxY - inset
        }
        if child?.appearance.shape == .underline, connector.endAxis == .horizontal,
           let frame = layout.frames[connector.childID] {
            end.y = frame.maxY - inset
        }
        if parent?.level == 0, connector.style == .curved, connector.startAxis == .horizontal,
           connector.endAxis == .horizontal, let frame = layout.frames[connector.parentID] {
            (start, startAxis) = MapScene.rootAnchor(rootFrame: frame, sideX: start.x, end: end)
        }
        let width = connector.lineWidth.map { CGFloat($0) } ?? MapScene.defaultLineWidth
        let geometry = ConnectorGeometry(
            start: start, end: end, startAxis: startAxis, endAxis: connector.endAxis,
            style: connector.style, startWidth: width, endWidth: width, dash: connector.dash
        )
        return StyledConnector(childID: connector.childID, geometry: geometry,
                               colorHex: child?.appearance.colorHex ?? ColorTheme.rootColorHex)
    }

    /// Start of a central topic edge on the root's side (`sideX`): a topic
    /// level with the root gets a straight horizontal line; others leave the
    /// root's upper/lower side region vertically and turn horizontal.
    static func rootAnchor(rootFrame: CGRect, sideX: CGFloat, end: CGPoint) -> (CGPoint, ConnectorAxis) {
        let band = rootFrame.height * 0.35
        if abs(end.y - rootFrame.midY) <= band {
            return (CGPoint(x: sideX, y: end.y), .horizontal)
        }
        let above = end.y < rootFrame.midY
        let y = above ? rootFrame.midY - band : rootFrame.midY + band
        return (CGPoint(x: sideX, y: y), .vertical)
    }
}
