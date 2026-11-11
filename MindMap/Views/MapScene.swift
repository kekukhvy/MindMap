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
    static func build(map: MindMap, measurer: NodeMeasurer, editing: (id: UUID, text: String)?) -> MapScene {
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
                                      isTreeRoot: isTreeRoot, badgeEdge: .trailing)
            order.append(node.id)
            guard !node.isCollapsed else { return }
            for child in node.children { visit(child, level: level + 1, isTreeRoot: false) }
        }
        visit(map.root, level: 0, isTreeRoot: true)
        for topic in map.floatingTopics { visit(topic.node, level: 1, isTreeRoot: true) }

        let layout = TreeLayout().layout(map) { id in
            guard let info = infos[id] else { return CGSize(width: 40, height: 20) }
            return measurer.nodeSize(text: info.text, appearance: info.appearance)
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

    /// Resolves widths/taper and moves endpoints onto underlines (XMind look).
    private func styled(_ connector: Connector) -> StyledConnector {
        let parent = nodes[connector.parentID]
        let child = nodes[connector.childID]
        var start = connector.start, end = connector.end
        let inset = NodeAppearance.underlineWidth / 2
        if parent?.appearance.shape == .underline, connector.startAxis == .horizontal,
           let frame = layout.frames[connector.parentID] {
            start.y = frame.maxY - inset
        }
        if child?.appearance.shape == .underline, connector.endAxis == .horizontal,
           let frame = layout.frames[connector.childID] {
            end.y = frame.maxY - inset
        }
        let fromRoot = parent?.level == 0
        let base = CGFloat(connector.lineWidth ?? (fromRoot ? 2 : 1.5))
        let tapered = fromRoot && connector.style == .curved && connector.dash == .solid
        let geometry = ConnectorGeometry(
            start: start, end: end, startAxis: connector.startAxis, endAxis: connector.endAxis,
            style: connector.style, startWidth: tapered ? base * 3 : base, endWidth: tapered ? base * 0.75 : base,
            dash: connector.dash
        )
        return StyledConnector(childID: connector.childID, geometry: geometry,
                               colorHex: child?.appearance.colorHex ?? ColorTheme.rootColorHex)
    }
}
