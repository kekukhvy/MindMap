import Foundation

/// A map as one plain Markdown note (library mirror for Obsidian, WP14b):
///
///     # <map title>
///     <central topic, if it differs from the title> + its notes
///     ## <main topic>            (also floating topics)
///     <its notes>
///     - subtopic                 (nested bullets; tasks as "- [ ]" / "- [x]")
///       note lines indented under their bullet
///
/// Web links become Markdown links; topic / map links are named after the
/// arrow. Markdown notes are included as text, handwriting and files by
/// name only. A locked note is NEVER written in plaintext: `noteText`
/// returns nil for it and a placeholder line is written instead.
enum MarkdownExport {
    static let lockedNotePlaceholder = "🔒 Locked note (not mirrored)"

    /// `noteText`: content of a plain Markdown note (nil = unreadable/locked).
    static func markdown(of map: MindMap, title: String, noteText: (Attachment) -> String?) -> String {
        var lines = ["# " + inline(title), ""]
        let rootText = inline(map.root.text)
        if !rootText.isEmpty, rootText != inline(title) {
            lines += [topicLine(map.root, map: map), ""]
        }
        appendAttachments(of: map.root, indent: "", into: &lines, noteText: noteText)
        for main in map.root.children + map.floatingTopics.map(\.node) {
            lines += ["## " + topicLine(main, map: map), ""]
            appendAttachments(of: main, indent: "", into: &lines, noteText: noteText)
            for child in main.children {
                appendBullets(child, level: 0, map: map, into: &lines, noteText: noteText)
            }
            if lines.last != "" { lines.append("") }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendBullets(_ node: Node, level: Int, map: MindMap, into lines: inout [String],
                                      noteText: (Attachment) -> String?) {
        let indent = String(repeating: "  ", count: level)
        let marker: String
        if let task = node.task { marker = task.isDone ? "- [x] " : "- [ ] " } else { marker = "- " }
        lines.append(indent + marker + topicLine(node, map: map, includeTask: false))
        appendAttachments(of: node, indent: indent + "  ", into: &lines, noteText: noteText)
        for child in node.children {
            appendBullets(child, level: level + 1, map: map, into: &lines, noteText: noteText)
        }
    }

    /// Topic text with task mark (headings) and link.
    private static func topicLine(_ node: Node, map: MindMap, includeTask: Bool = true) -> String {
        var text = inline(node.text)
        if text.isEmpty { text = "(empty topic)" }
        switch node.link {
        case let .web(url)?:
            text = "[\(text)](\(url.absoluteString))"
        case let .topic(id)?:
            if let target = map.node(withID: id) { text += " → *\(inline(target.text))*" }
        case let .map(reference)?:
            text += " → *\(inline(reference.displayName))*"
        case .unknown?, nil:
            break
        }
        if includeTask, let task = node.task { text = (task.isDone ? "☑ " : "☐ ") + text }
        return text
    }

    private static func appendAttachments(of node: Node, indent: String, into lines: inout [String],
                                          noteText: (Attachment) -> String?) {
        for attachment in node.attachments {
            switch attachment.kind {
            case .markdown:
                if attachment.isLocked {
                    lines.append(indent + lockedNotePlaceholder)
                    continue
                }
                guard let text = noteText(attachment)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                if indent.isEmpty { lines.append("") }
                lines += text.components(separatedBy: .newlines).map { $0.isEmpty ? "" : indent + $0 }
                if indent.isEmpty { lines.append("") }
            case .drawing:
                lines.append(indent + (attachment.isLocked ? lockedNotePlaceholder
                                                           : "✏️ Handwritten note" + titleSuffix(attachment)))
            case .file:
                lines.append(indent + "📎 " + (attachment.title.isEmpty ? attachment.fileName : inline(attachment.title)))
            }
        }
    }

    private static func titleSuffix(_ attachment: Attachment) -> String {
        attachment.title.isEmpty ? "" : ": " + inline(attachment.title)
    }

    /// One line (topics can hold line breaks).
    static func inline(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
