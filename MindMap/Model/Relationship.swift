import CoreGraphics
import Foundation

/// Cross-link between any two nodes (tree or floating).
struct Relationship: Identifiable, Equatable, Codable {
    var id: UUID
    var fromNodeID: UUID
    var toNodeID: UUID
    var label: String?
    /// Optional control-point offsets relative to the start / end anchors.
    /// nil = automatic arc.
    var fromControlOffset: CGVector?
    var toControlOffset: CGVector?
    var style: RelationshipStyle

    init(id: UUID = UUID(), from: UUID, to: UUID, label: String? = nil,
         fromControlOffset: CGVector? = nil, toControlOffset: CGVector? = nil,
         style: RelationshipStyle = RelationshipStyle()) {
        self.id = id
        self.fromNodeID = from
        self.toNodeID = to
        self.label = label
        self.fromControlOffset = fromControlOffset
        self.toControlOffset = toControlOffset
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromNodeID, toNodeID, label, fromControlOffset, toControlOffset, style
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fromNodeID = try c.decode(UUID.self, forKey: .fromNodeID)
        toNodeID = try c.decode(UUID.self, forKey: .toNodeID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        fromControlOffset = try c.decodeIfPresent(CGVector.self, forKey: .fromControlOffset)
        toControlOffset = try c.decodeIfPresent(CGVector.self, forKey: .toControlOffset)
        style = try c.decodeIfPresent(RelationshipStyle.self, forKey: .style) ?? RelationshipStyle()
    }
}
