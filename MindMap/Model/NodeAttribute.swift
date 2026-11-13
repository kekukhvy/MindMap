import CoreGraphics
import Foundation

/// One settable node property with its value. Used by `TreeEdit.set` so
/// every property change is invertible by a single generic edit.
enum NodeAttribute: Equatable {
    case text(String)
    case collapsed(Bool)
    case colorTag(ColorTag)
    case customColor(String?)
    case layoutStyle(LayoutStyle?)
    case shape(NodeShape?)
    case borderStyle(BorderStyle?)
    case connectorStyle(ConnectorStyle?)
    case lineWidth(Double?)
    case lineDash(LineDash?)
    case manualPosition(CGPoint?)
    /// Side under a balanced-map parent (WP17).
    case side(BranchSide?)
    case link(TopicLink?)
    case task(TaskInfo?)
    /// The whole attachment list (add/remove/rename/reorder = one set).
    case attachments([Attachment])

    /// The same attribute kind, holding `node`'s current value.
    func current(in node: Node) -> NodeAttribute {
        switch self {
        case .text: return .text(node.text)
        case .collapsed: return .collapsed(node.isCollapsed)
        case .colorTag: return .colorTag(node.colorTag)
        case .customColor: return .customColor(node.customColor)
        case .layoutStyle: return .layoutStyle(node.layoutStyle)
        case .shape: return .shape(node.shape)
        case .borderStyle: return .borderStyle(node.borderStyle)
        case .connectorStyle: return .connectorStyle(node.connectorStyle)
        case .lineWidth: return .lineWidth(node.lineWidth)
        case .lineDash: return .lineDash(node.lineDash)
        case .manualPosition: return .manualPosition(node.manualPosition)
        case .side: return .side(node.side)
        case .link: return .link(node.link)
        case .task: return .task(node.task)
        case .attachments: return .attachments(node.attachments)
        }
    }

    func write(to node: inout Node) {
        switch self {
        case let .text(v): node.text = v
        case let .collapsed(v): node.isCollapsed = v
        case let .colorTag(v): node.colorTag = v
        case let .customColor(v): node.customColor = v
        case let .layoutStyle(v): node.layoutStyle = v
        case let .shape(v): node.shape = v
        case let .borderStyle(v): node.borderStyle = v
        case let .connectorStyle(v): node.connectorStyle = v
        case let .lineWidth(v): node.lineWidth = v
        case let .lineDash(v): node.lineDash = v
        case let .manualPosition(v): node.manualPosition = v
        case let .side(v): node.side = v
        case let .link(v): node.link = v
        case let .task(v): node.task = v
        case let .attachments(v): node.attachments = v
        }
    }
}
