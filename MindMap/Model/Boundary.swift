import Foundation

/// Grouping outline ("zone") around arbitrary topics: every member is
/// enclosed with its visible subtree. Members may sit in different branches
/// (e.g. one child of A and one child of B); the outline then follows the
/// union of their subtrees (`BoundaryHull`).
///
/// JSON: `memberIDs` (+ `nodeID` = first member, so older versions still
/// open the file). Files written before multi-member boundaries have
/// `nodeID` + optional `siblingIDs`; they decode as members
/// `[nodeID] + siblingIDs`.
struct Boundary: Identifiable, Equatable, Codable {
    var id: UUID
    /// Enclosed topics (document order, no duplicates). Never empty in a
    /// valid map: a boundary whose last member goes away is removed.
    var memberIDs: [UUID]
    var label: String?
    /// "#RRGGBB"; nil = derived from the first member's color by the view.
    var colorHex: String?

    init(id: UUID = UUID(), memberIDs: [UUID], label: String? = nil, colorHex: String? = nil) {
        self.id = id
        var seen = Set<UUID>()
        self.memberIDs = memberIDs.filter { seen.insert($0).inserted }
        self.label = label
        self.colorHex = colorHex
    }

    /// Boundary around one topic's subtree (+ optional extra topics).
    init(id: UUID = UUID(), nodeID: UUID, siblingIDs: [UUID] = [], label: String? = nil, colorHex: String? = nil) {
        self.init(id: id, memberIDs: [nodeID] + siblingIDs, label: label, colorHex: colorHex)
    }

    var hasLabel: Bool { !(label ?? "").isEmpty }

    /// First member (its branch color is the default outline color).
    var primaryMemberID: UUID? { memberIDs.first }

    private enum CodingKeys: String, CodingKey { case id, memberIDs, nodeID, siblingIDs, label, colorHex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        if let members = try c.decodeIfPresent([UUID].self, forKey: .memberIDs), !members.isEmpty {
            var seen = Set<UUID>()
            memberIDs = members.filter { seen.insert($0).inserted }
        } else {
            // Legacy single-subtree / sibling-range boundary.
            let nodeID = try c.decode(UUID.self, forKey: .nodeID)
            let siblings = try c.decodeIfPresent([UUID].self, forKey: .siblingIDs) ?? []
            var seen = Set<UUID>()
            memberIDs = ([nodeID] + siblings).filter { seen.insert($0).inserted }
        }
        label = try c.decodeIfPresent(String.self, forKey: .label)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(memberIDs, forKey: .memberIDs)
        // Read by versions before multi-member boundaries (they need it).
        try c.encodeIfPresent(memberIDs.first, forKey: .nodeID)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(colorHex, forKey: .colorHex)
    }
}

extension MindMap {
    /// Members of `boundary` that exist, without topics whose ancestor is a
    /// member too (the ancestor already encloses them), in document order.
    func normalizedMembers(of boundary: Boundary) -> [UUID] {
        normalizedTopics(boundary.memberIDs)
    }

    /// `ids` that exist, without duplicates and without topics that have an
    /// ancestor in `ids`, sorted in document order (main tree pre-order,
    /// then floating topics).
    func normalizedTopics(_ ids: some Sequence<UUID>) -> [UUID] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }
        var result: [UUID] = []
        func visit(_ node: Node) {
            if wanted.contains(node.id) {
                result.append(node.id)
                return
            }
            for child in node.children { visit(child) }
        }
        visit(root)
        for topic in floatingTopics { visit(topic.node) }
        return result
    }

    /// `ids` that exist, in document order (descendants kept).
    func documentOrder(_ ids: some Sequence<UUID>) -> [UUID] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }
        var result: [UUID] = []
        func visit(_ node: Node) {
            if wanted.contains(node.id) { result.append(node.id) }
            for child in node.children { visit(child) }
        }
        visit(root)
        for topic in floatingTopics { visit(topic.node) }
        return result
    }
}
