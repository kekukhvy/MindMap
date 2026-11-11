import Foundation

/// Grouping outline around `nodeID`'s whole subtree, optionally extended to
/// the subtrees of some of its siblings (`siblingIDs`).
struct Boundary: Identifiable, Equatable, Codable {
    var id: UUID
    var nodeID: UUID
    var siblingIDs: [UUID]
    var label: String?
    /// "#RRGGBB"; nil = derived from the node's color by the view.
    var colorHex: String?

    init(id: UUID = UUID(), nodeID: UUID, siblingIDs: [UUID] = [], label: String? = nil, colorHex: String? = nil) {
        self.id = id
        self.nodeID = nodeID
        self.siblingIDs = siblingIDs
        self.label = label
        self.colorHex = colorHex
    }

    var hasLabel: Bool { !(label ?? "").isEmpty }

    /// Nodes whose subtrees are enclosed.
    var enclosedRootIDs: [UUID] { [nodeID] + siblingIDs }

    private enum CodingKeys: String, CodingKey { case id, nodeID, siblingIDs, label, colorHex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        nodeID = try c.decode(UUID.self, forKey: .nodeID)
        siblingIDs = try c.decodeIfPresent([UUID].self, forKey: .siblingIDs) ?? []
        label = try c.decodeIfPresent(String.self, forKey: .label)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
    }
}
