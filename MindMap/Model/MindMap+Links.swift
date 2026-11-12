import Foundation

/// A topic's link as it resolves in the current map.
enum ResolvedLink: Equatable {
    case web(URL)
    case topic(UUID)
    /// Topic link whose target no longer exists (deleted; undo restores it).
    case brokenTopic(UUID)
    /// Another map file (found on disk only when followed).
    case map(MapReference)

    var isBroken: Bool {
        if case .brokenTopic = self { return true }
        return false
    }
}

/// One topic offered as a link target (editor list, search).
struct LinkCandidate: Equatable, Identifiable {
    var id: UUID
    var text: String
    /// Ancestor texts from the tree root down to the parent (empty for roots).
    var ancestors: [String]

    /// "Central Topic › Main Topic" (empty for roots).
    var breadcrumb: String { ancestors.joined(separator: " › ") }
}

/// Topic links: resolution, paths, candidates and edits (one undo step each).
extension MindMap {
    /// `id`'s link if this version understands it (`.unknown` = no link).
    func link(of id: UUID) -> TopicLink? {
        guard let link = node(withID: id)?.link, link.isKnown else { return nil }
        return link
    }

    func resolvedLink(of id: UUID) -> ResolvedLink? {
        switch link(of: id) {
        case let .web(url): return .web(url)
        case let .topic(target): return contains(target) ? .topic(target) : .brokenTopic(target)
        case let .map(reference): return .map(reference)
        case .unknown, nil: return nil
        }
    }

    /// Texts from the tree root (main or floating) down to `id` itself.
    func textPath(to id: UUID) -> [String]? {
        guard let tree = tree(containing: id), let path = tree.path(to: id) else { return nil }
        var current = tree
        var texts = [tree.text]
        for index in path {
            current = current.children[index]
            texts.append(current.text)
        }
        return texts
    }

    /// "Central Topic › Main Topic › Target" (nil if `id` does not exist).
    func breadcrumb(to id: UUID) -> String? {
        textPath(to: id).map { $0.map(LinkCandidate.displayText).joined(separator: " › ") }
    }

    /// Every topic (main tree first, then floating topics, pre-order) except
    /// `excluded`, matching `query` in its text or breadcrumb (case and
    /// diacritic insensitive; empty query = all).
    func linkCandidates(matching query: String = "", excluding excluded: UUID? = nil) -> [LinkCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [LinkCandidate] = []
        func visit(_ node: Node, ancestors: [String]) {
            if node.id != excluded {
                let candidate = LinkCandidate(id: node.id, text: LinkCandidate.displayText(node.text),
                                              ancestors: ancestors)
                if needle.isEmpty || candidate.text.localizedStandardContains(needle)
                    || candidate.breadcrumb.localizedStandardContains(needle) {
                    result.append(candidate)
                }
            }
            for child in node.children { visit(child, ancestors: ancestors + [LinkCandidate.displayText(node.text)]) }
        }
        for tree in trees { visit(tree, ancestors: []) }
        return result
    }

    /// Sets / clears `id`'s link. A topic link must point to another
    /// existing topic. Empty = no change.
    func setLinkEdits(_ link: TopicLink?, for id: UUID) throws -> [MapEdit] {
        guard let node = node(withID: id) else { throw TreeEditError.nodeNotFound }
        if let target = link?.topicID, target == id || !contains(target) { throw TreeEditError.invalidLink }
        if let reference = link?.mapReference, !reference.isUsable { throw TreeEditError.invalidLink }
        guard node.link != link else { return [] }
        return try setAttributeEdits(.link(link), for: id)
    }

    /// Every topic linking to another map, in map order.
    var mapLinks: [(id: UUID, reference: MapReference)] {
        trees.flatMap(\.allNodes).compactMap { node in node.link?.mapReference.map { (node.id, $0) } }
    }

    /// Replaces map references (refreshed path / bookmark) without checks.
    func updateMapLinkEdits(_ updates: [UUID: MapReference]) -> [MapEdit] {
        var edits: [MapEdit] = []
        for (id, reference) in updates {
            guard let node = node(withID: id), node.link?.mapReference != nil, node.link != .map(reference),
                  let set = try? setAttributeEdits(.link(.map(reference)), for: id) else { continue }
            edits += set
        }
        return edits
    }

    /// Collapsed ancestors of `id` (nearest first).
    func collapsedAncestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var current = id
        while let parent = parentID(of: current) {
            if node(withID: parent)?.isCollapsed == true { result.append(parent) }
            current = parent
        }
        return result
    }

    /// Expands every collapsed ancestor so `id` becomes visible (empty if it is).
    func revealEdits(_ id: UUID) -> [MapEdit] {
        collapsedAncestors(of: id).map { .tree(.setCollapsed(id: $0, false)) }
    }
}

extension LinkCandidate {
    /// Placeholder for topics without text.
    static func displayText(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled Topic" : trimmed
    }
}
