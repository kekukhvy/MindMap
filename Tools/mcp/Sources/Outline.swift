import Foundation

/// The text `read_map` returns: an indented outline with topic ids and flags.
enum Outline {
    static let indent = "  "
    static let floatingHeading = "Floating topics:"

    static func topicCount(_ map: MindMap) -> Int {
        map.trees.reduce(0) { $0 + $1.allIDs.count }
    }

    static func render(_ map: MindMap, name: String, mapID: String) -> String {
        var lines = ["Map \"\(name)\" (map id \(mapID), \(topicCount(map)) topics)"]
        append(map.root, depth: 0, to: &lines)
        if !map.floatingTopics.isEmpty {
            lines.append(floatingHeading)
            for floating in map.floatingTopics { append(floating.node, depth: 0, to: &lines) }
        }
        return lines.joined(separator: "\n")
    }

    /// Lines for a node and its descendants (also used for the topics `add_topics` created).
    static func append(_ node: Node, depth: Int, to lines: inout [String]) {
        let marker = node.task.map { $0.isDone ? "[x] " : "[ ] " } ?? ""
        let text = marker + TopicTextInput.singleLine(node.text)
        lines.append("\(String(repeating: indent, count: depth))- \(text) [\(node.id.uuidString)]\(flags(node))")
        node.children.forEach { append($0, depth: depth + 1, to: &lines) }
    }

    private static func flags(_ node: Node) -> String {
        var parts: [String] = []
        for attachment in node.attachments where attachment.kind == .markdown {
            parts.append((attachment.isLocked ? "locked-note=" : "note=") + attachment.id.uuidString)
        }
        if node.link != nil { parts.append("link") }
        if node.isCollapsed && !node.children.isEmpty { parts.append("collapsed") }
        let others = node.attachments.filter { $0.kind != .markdown }.count
        if others > 0 { parts.append("attachments=\(others)") }
        return parts.isEmpty ? "" : " {" + parts.joined(separator: ", ") + "}"
    }
}
