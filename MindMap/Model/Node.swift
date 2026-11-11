import CoreGraphics
import Foundation

/// A single topic in the mind map. Value type: the whole tree is a nested
/// `Node` value, which makes snapshots, undo and Codable trivial.
/// All optional style fields mean "inherit / default" when nil.
struct Node: Identifiable, Equatable, Codable {
    var id: UUID
    var text: String
    var isCollapsed: Bool
    var colorTag: ColorTag
    /// "#RRGGBB" override of the theme color for this node only.
    var customColor: String?
    /// How descendants are arranged; nil = inherit (see `LayoutStyle`).
    var layoutStyle: LayoutStyle?
    /// nil = default by depth (`NodeShape.defaultShape(forDepth:)`).
    var shape: NodeShape?
    /// nil = `.solid`.
    var borderStyle: BorderStyle?
    /// Lines to children (inherited by descendants); nil = inherit.
    var connectorStyle: ConnectorStyle?
    /// Branch line width (inherited); nil = inherit / renderer default.
    var lineWidth: Double?
    /// Branch line dash (inherited); nil = inherit / solid.
    var lineDash: LineDash?
    /// Free position set by dragging: offset of this node's center from its
    /// parent's center (map points). nil = placed by the parent's layout.
    /// Ignored on tree roots (floating topics use `FloatingTopic.position`).
    var manualPosition: CGPoint?
    var children: [Node]
    var attachments: [Attachment]

    init(
        id: UUID = UUID(),
        text: String = "",
        isCollapsed: Bool = false,
        colorTag: ColorTag = .none,
        customColor: String? = nil,
        layoutStyle: LayoutStyle? = nil,
        shape: NodeShape? = nil,
        borderStyle: BorderStyle? = nil,
        connectorStyle: ConnectorStyle? = nil,
        lineWidth: Double? = nil,
        lineDash: LineDash? = nil,
        manualPosition: CGPoint? = nil,
        children: [Node] = [],
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.text = text
        self.isCollapsed = isCollapsed
        self.colorTag = colorTag
        self.customColor = customColor
        self.layoutStyle = layoutStyle
        self.shape = shape
        self.borderStyle = borderStyle
        self.connectorStyle = connectorStyle
        self.lineWidth = lineWidth
        self.lineDash = lineDash
        self.manualPosition = manualPosition
        self.children = children
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, isCollapsed, colorTag, customColor, layoutStyle, shape, borderStyle
        case connectorStyle, lineWidth, lineDash, manualPosition, children, attachments
    }

    /// Tolerant decoding: every field except `id` is optional in the file;
    /// unknown enum values (from newer versions) fall back to nil/default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        colorTag = try c.decodeIfPresent(ColorTag.self, forKey: .colorTag) ?? .none
        customColor = try c.decodeIfPresent(String.self, forKey: .customColor)
        layoutStyle = (try? c.decodeIfPresent(LayoutStyle.self, forKey: .layoutStyle)) ?? nil
        shape = (try? c.decodeIfPresent(NodeShape.self, forKey: .shape)) ?? nil
        borderStyle = (try? c.decodeIfPresent(BorderStyle.self, forKey: .borderStyle)) ?? nil
        connectorStyle = (try? c.decodeIfPresent(ConnectorStyle.self, forKey: .connectorStyle)) ?? nil
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth)
        lineDash = (try? c.decodeIfPresent(LineDash.self, forKey: .lineDash)) ?? nil
        manualPosition = (try? c.decodeIfPresent(CGPoint.self, forKey: .manualPosition)) ?? nil
        children = try c.decodeIfPresent([Node].self, forKey: .children) ?? []
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }
}
