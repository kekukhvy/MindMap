import Foundation

/// One topic found by Find (⌘F): its own text, or one of its notes.
struct FindMatch: Equatable {
    let topicID: UUID
    /// The markdown note that holds the phrase (nil = the topic text itself).
    var noteID: UUID?
    /// The note line holding the phrase (empty for a topic text match).
    var snippet = ""
}

extension MindMap {
    /// Longest note snippet shown in the find bar.
    static let findSnippetLength = 80

    /// Topics (main tree first, then floating topics, pre-order) whose text
    /// or markdown note contains `query` as a whole phrase (case and
    /// diacritic insensitive). Locked notes are never searched. Empty query
    /// = no matches. `noteText` reads a note's text.
    func findMatches(_ query: String, noteText: (Attachment) -> String?) -> [FindMatch] {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return [] }
        var result: [FindMatch] = []
        func visit(_ node: Node) {
            if node.text.localizedStandardContains(phrase) {
                result.append(FindMatch(topicID: node.id))
            } else if let hit = noteHit(in: node, phrase: phrase, noteText: noteText) {
                result.append(hit)
            }
            node.children.forEach(visit)
        }
        trees.forEach(visit)
        return result
    }

    private func noteHit(in node: Node, phrase: String, noteText: (Attachment) -> String?) -> FindMatch? {
        for note in node.attachments where note.kind == .markdown && !note.isLocked {
            guard let text = noteText(note), text.localizedStandardContains(phrase) else { continue }
            let line = text.split(whereSeparator: \.isNewline).first { $0.localizedStandardContains(phrase) }
            let snippet = (line.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            return FindMatch(topicID: node.id, noteID: note.id, snippet: String(snippet.prefix(Self.findSnippetLength)))
        }
        return nil
    }

    /// The matched topics plus all their ancestors (what the filter shows).
    func findVisibleIDs(_ matches: [FindMatch]) -> Set<UUID> {
        var ids = Set<UUID>()
        for match in matches {
            var current: UUID? = match.topicID
            while let id = current, ids.insert(id).inserted { current = parentID(of: id) }
        }
        return ids
    }

    /// A copy showing only `ids` (the central topic always stays), branches
    /// open. View state: the document itself is not touched. Relationships
    /// and boundaries are kept only when all their topics are shown.
    func filtered(keeping ids: Set<UUID>) -> MindMap {
        func prune(_ node: Node) -> Node {
            var copy = node
            copy.children = node.children.filter { ids.contains($0.id) }.map(prune)
            copy.isCollapsed = false
            return copy
        }
        let shown = ids.union([root.id])
        var copy = self
        copy.relationships = relationships.filter { shown.contains($0.fromNodeID) && shown.contains($0.toNodeID) }
        copy.boundaries = boundaries.filter { shown.isSuperset(of: $0.memberIDs) }
        copy.root = prune(root)
        copy.floatingTopics = floatingTopics.filter { ids.contains($0.id) }.map {
            FloatingTopic(node: prune($0.node), position: $0.position)
        }
        return copy
    }
}

extension MindMapModel {
    /// Find matches in the open map; notes are read from the package.
    func findMatches(_ query: String) -> [FindMatch] {
        map.findMatches(query) { note in
            content(of: note.id).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
