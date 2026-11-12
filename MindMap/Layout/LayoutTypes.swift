import CoreGraphics
import Foundation

/// Horizontal growth direction of a branch (left-side branches mirror).
enum HorizontalDirection: Equatable {
    case right, left
}

/// Tangent axis of a connector at one of its ends.
enum ConnectorAxis: Equatable {
    case horizontal, vertical
}

/// Geometry + resolved style of one parent→child edge. The renderer only
/// draws it: `curved` = cubic with tangents along the axes; `elbow` /
/// `roundedElbow` = orthogonal polyline following the axes (H→H: horizontal,
/// vertical at mid-x, horizontal; V→H: vertical down to end.y, then
/// horizontal; V→V: vertical, horizontal at mid-y, vertical); `straight` = line.
struct Connector: Equatable {
    var parentID: UUID
    var childID: UUID
    var start: CGPoint
    var end: CGPoint
    var startAxis: ConnectorAxis
    var endAxis: ConnectorAxis
    var style: ConnectorStyle
    /// nil = renderer default width.
    var lineWidth: Double?
    var dash: LineDash

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Connector {
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        return copy
    }
}

/// Spacing configuration for all layout styles.
struct LayoutSpacing: Equatable {
    /// Gap between a parent and its children column (horizontal maps).
    var horizontal: CGFloat = 24
    /// Gap between vertically stacked sibling subtrees.
    var vertical: CGFloat = 10
    /// `horizontal` for the central topic's children (XMind: wide root gap).
    var rootHorizontal: CGFloat = 72
    /// `vertical` between the central topic's child subtrees (main topics).
    var rootVertical: CGFloat = 30
    /// Indent of children in `.treeDown`.
    var treeIndent: CGFloat = 28
    /// Gap between a parent and the children below it (`.treeDown`, `.orgChartDown`).
    var levelGap: CGFloat = 16
    /// Gap between side-by-side sibling subtrees in `.orgChartDown`.
    var rowGap: CGFloat = 16
    /// Padding between a boundary outline and its enclosed frames.
    var boundaryPadding: CGFloat = 10
    /// Extra space above enclosed frames for a boundary label.
    var boundaryLabelHeight: CGFloat = 20

    /// Spacing used by the central topic's arranger (root gaps).
    var forCentralTopic: LayoutSpacing {
        var copy = self
        copy.horizontal = rootHorizontal
        copy.vertical = rootVertical
        return copy
    }
}

/// Inherited layout context a parent hands to a child subtree.
struct LayoutContext: Equatable {
    var style: LayoutStyle
    var direction: HorizontalDirection
    /// Inherited branch line properties (nil = default for the arranger).
    var connectorStyle: ConnectorStyle?
    var lineWidth: Double?
    var lineDash: LineDash?

    static let root = LayoutContext(style: LayoutStyle.rootDefault, direction: .right)
    static let floating = LayoutContext(style: .rightMap, direction: .right)

    /// Context in effect for `node`: its explicit values, or inherited ones.
    func resolved(for node: Node) -> LayoutContext {
        var result = self
        if let style = node.layoutStyle {
            result.style = style
            switch style {
            case .rightMap: result.direction = .right
            case .leftMap: result.direction = .left
            case .balancedMap, .treeDown, .orgChartDown: break
            }
        }
        if let value = node.connectorStyle { result.connectorStyle = value }
        if let value = node.lineWidth { result.lineWidth = value }
        if let value = node.lineDash { result.lineDash = value }
        return result
    }

    /// Context handed to children, keeping inherited line properties.
    func passingDown(style: LayoutStyle, direction: HorizontalDirection) -> LayoutContext {
        var result = self
        result.style = style
        result.direction = direction
        return result
    }

    /// Context for children placed in a horizontal map on `side`.
    func horizontal(_ side: HorizontalDirection) -> LayoutContext {
        passingDown(style: side == .right ? .rightMap : .leftMap, direction: side)
    }

    /// Builds the connector for an edge leaving the node of this context.
    func connector(from parentID: UUID, to childID: UUID, start: CGPoint, end: CGPoint,
                   axes: (ConnectorAxis, ConnectorAxis), defaultStyle: ConnectorStyle) -> Connector {
        Connector(parentID: parentID, childID: childID, start: start, end: end,
                  startAxis: axes.0, endAxis: axes.1, style: connectorStyle ?? defaultStyle,
                  lineWidth: lineWidth, dash: lineDash ?? .solid)
    }
}
