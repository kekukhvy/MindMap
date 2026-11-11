import Foundation

/// Branch (parent→child) line style. Set on a node, it applies to the lines
/// from that node to its children and is inherited by descendants
/// (nil = inherit; root's value acts as map default; built-in default
/// depends on the parent's layout: curved for maps, elbow for tree/org).
enum ConnectorStyle: String, Codable, CaseIterable {
    /// XMind default (renderer may taper the width).
    case curved
    case straight
    case elbow
    case roundedElbow
}

enum LineDash: String, Codable, CaseIterable {
    case solid, dashed, dotted
}

enum ArrowHead: String, Codable, CaseIterable {
    case none, arrow, filledArrow, dot, diamond
}

enum RelationshipPathStyle: String, Codable, CaseIterable {
    case curved, straight, elbow
}

/// Line style of a relationship (cross-link). Defaults are XMind-like.
struct RelationshipStyle: Equatable, Codable {
    var path: RelationshipPathStyle = .curved
    var dash: LineDash = .dashed
    var startArrow: ArrowHead = .none
    var endArrow: ArrowHead = .arrow
    var width: Double = 1.5
    /// "#RRGGBB"; nil = default relationship color.
    var colorHex: String?

    init(path: RelationshipPathStyle = .curved, dash: LineDash = .dashed, startArrow: ArrowHead = .none,
         endArrow: ArrowHead = .arrow, width: Double = 1.5, colorHex: String? = nil) {
        self.path = path
        self.dash = dash
        self.startArrow = startArrow
        self.endArrow = endArrow
        self.width = width
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey { case path, dash, startArrow, endArrow, width, colorHex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decodeIfPresent(RelationshipPathStyle.self, forKey: .path)) ?? .curved
        dash = (try? c.decodeIfPresent(LineDash.self, forKey: .dash)) ?? .dashed
        startArrow = (try? c.decodeIfPresent(ArrowHead.self, forKey: .startArrow)) ?? ArrowHead.none
        endArrow = (try? c.decodeIfPresent(ArrowHead.self, forKey: .endArrow)) ?? .arrow
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1.5
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
    }
}
