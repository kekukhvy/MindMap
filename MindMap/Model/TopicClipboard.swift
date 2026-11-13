import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Copied topics on the system clipboard (`TopicClipboard` JSON).
    static let mindMapTopics = UTType(exportedAs: "com.kekukh.mindmap.topics", conformingTo: .json)
}

/// Copied topics (⌘C / ⌘X): the subtrees with every style, task, link and
/// attachment (file bytes included), plus the relationships and boundaries
/// that lie entirely inside them. Pasting makes fresh copies (`instantiate`).
struct TopicClipboard: Codable, Equatable {
    var format = 1
    /// Copied subtrees, document order, none inside another.
    var topics: [Node]
    var relationships: [Relationship] = []
    var boundaries: [Boundary] = []
    /// Attachment bytes by file name (attachments without bytes are dropped
    /// when pasting, e.g. locked notes: their key is bound to their id).
    var files: [String: Data] = [:]

    init(topics: [Node], relationships: [Relationship] = [], boundaries: [Boundary] = [],
         files: [String: Data] = [:]) {
        self.topics = topics
        self.relationships = relationships
        self.boundaries = boundaries
        self.files = files
    }

    var isEmpty: Bool { topics.isEmpty }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> TopicClipboard? {
        guard let clip = try? JSONDecoder().decode(TopicClipboard.self, from: data), !clip.isEmpty else { return nil }
        return clip
    }

    // MARK: Paste

    /// What a paste inserts: copies with new ids (topics, attachments,
    /// relationships, boundaries), topic links between copied topics pointing
    /// at the copies, and the bytes to store under the new file names.
    struct Instance: Equatable {
        var topics: [Node]
        var relationships: [Relationship]
        var boundaries: [Boundary]
        var files: [String: Data]
    }

    func instantiate() -> Instance {
        var ids: [UUID: UUID] = [:]
        func collect(_ node: Node) {
            ids[node.id] = UUID()
            node.children.forEach(collect)
        }
        topics.forEach(collect)
        var newFiles: [String: Data] = [:]
        func copy(_ node: Node, top: Bool) -> Node {
            var result = node
            result.id = ids[node.id]!
            if case let .topic(target)? = node.link, let mapped = ids[target] { result.link = .topic(mapped) }
            result.attachments = node.attachments.compactMap { attachment in
                guard attachment.lockKeyID == nil, let data = files[attachment.fileName] else { return nil }
                var fresh = attachment
                fresh.id = UUID()
                let ext = (attachment.fileName as NSString).pathExtension
                fresh.fileName = Attachment.defaultFileName(id: fresh.id, kind: attachment.kind,
                                                            originalExtension: ext.isEmpty ? nil : ext)
                newFiles[fresh.fileName] = data
                if attachment.kind == .markdown { renameImages(of: attachment, to: fresh, files: &newFiles) }
                return fresh
            }
            result.children = node.children.map { copy($0, top: false) }
            if top {
                // A pasted topic is laid out by its new parent.
                result.manualPosition = nil
                result.side = nil
                if result.layoutStyle == .balancedMap { result.layoutStyle = nil }
            }
            return result
        }
        let copies = topics.map { copy($0, top: true) }
        let relationships = self.relationships.compactMap { relationship -> Relationship? in
            guard let from = ids[relationship.fromNodeID], let to = ids[relationship.toNodeID] else { return nil }
            var fresh = relationship
            fresh.id = UUID()
            fresh.fromNodeID = from
            fresh.toNodeID = to
            return fresh
        }
        let boundaries = self.boundaries.compactMap { boundary -> Boundary? in
            let members = boundary.memberIDs.compactMap { ids[$0] }
            guard !members.isEmpty, members.count == boundary.memberIDs.count else { return nil }
            var fresh = boundary
            fresh.id = UUID()
            fresh.memberIDs = members
            return fresh
        }
        return Instance(topics: copies, relationships: relationships, boundaries: boundaries, files: newFiles)
    }

    /// A pasted note gets a new id: its images are stored under the new
    /// prefix and the links in `files[fresh.fileName]` follow.
    private func renameImages(of old: Attachment, to fresh: Attachment, files newFiles: inout [String: Data]) {
        let oldPrefix = NoteImage.ownerPrefix(of: old.id)
        var text = newFiles[fresh.fileName].map { MarkdownNote.text($0) }
        for (name, data) in files where name.hasPrefix(oldPrefix) {
            let newName = NoteImage.ownerPrefix(of: fresh.id) + name.dropFirst(oldPrefix.count)
            newFiles[newName] = data
            text = text?.replacingOccurrences(of: NoteImage.linkFolder + name, with: NoteImage.linkFolder + newName)
        }
        if let text { newFiles[fresh.fileName] = MarkdownNote.data(text) }
    }

    // MARK: Plain text

    /// Outline for other apps: one line per topic, a tab per level (the
    /// format XMind / MindManager / outliners paste as topics again).
    var plainText: String {
        var lines: [String] = []
        func visit(_ node: Node, depth: Int) {
            let text = TopicTextInput.singleLine(node.text)
            lines.append(String(repeating: "\t", count: depth) + text)
            node.children.forEach { visit($0, depth: depth + 1) }
        }
        topics.forEach { visit($0, depth: 0) }
        return lines.joined(separator: "\n")
    }

    /// Topics from plain text: every non-empty line is a topic, indented
    /// lines (tabs, or 2 spaces per level) are children of the line above;
    /// list markers ("- ", "* ", "• ", "1. ") are dropped and Markdown task
    /// items ("- [ ] ", "- [x] ") become tasks.
    init?(plainText: String) {
        struct Line { var depth: Int; var node: Node }
        var lines: [Line] = []
        for raw in plainText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines) {
            var indent = 0
            var rest = Substring(raw)
            while let first = rest.first, first == "\t" || first == " " {
                indent += first == "\t" ? 2 : 1
                rest.removeFirst()
            }
            var text = String(rest).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var task: TaskInfo?
            for (marker, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false),
                                   ("* [x] ", true)] where text.hasPrefix(marker) {
                task = TaskInfo(isDone: done)
                text = String(text.dropFirst(marker.count))
                break
            }
            if task == nil {
                if let marker = ["- ", "* ", "+ ", "• "].first(where: text.hasPrefix) {
                    text = String(text.dropFirst(marker.count))
                } else if let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }), dot > text.startIndex,
                          text[..<dot].allSatisfy(\.isNumber), text[text.index(after: dot)...].hasPrefix(" ") {
                    text = String(text[text.index(dot, offsetBy: 2)...])
                }
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            lines.append(Line(depth: indent / 2, node: Node(text: text, task: task)))
        }
        guard !lines.isEmpty else { return nil }
        // Build the forest: each line goes under the nearest shallower line.
        var stack: [(depth: Int, node: Node)] = []
        var roots: [Node] = []
        func popLast() {
            let (_, node) = stack.removeLast()
            if stack.isEmpty { roots.append(node) } else { stack[stack.count - 1].node.children.append(node) }
        }
        let base = lines.map(\.depth).min() ?? 0
        for line in lines {
            let depth = line.depth - base
            while let last = stack.last, last.depth >= depth { popLast() }
            stack.append((depth, line.node))
        }
        while !stack.isEmpty { popLast() }
        self.init(topics: roots)
    }
}

extension MindMap {
    /// Clipboard of `ids` (central topic allowed: it is copied as a topic),
    /// ancestors win over their descendants; `content` gives attachment
    /// bytes (nil = not copied); `images` gives the image files of a note.
    func clipboard(for ids: [UUID], content: (Attachment) -> Data?,
                   images: (Attachment) -> [String: Data] = { _ in [:] }) -> TopicClipboard? {
        let wanted = Set(ids.filter(contains))
        guard !wanted.isEmpty else { return nil }
        var topics: [Node] = []
        func visit(_ node: Node) {
            if wanted.contains(node.id) {
                topics.append(node)
            } else {
                node.children.forEach(visit)
            }
        }
        visit(root)
        floatingTopics.forEach { visit($0.node) }
        var inside = Set<UUID>()
        var files: [String: Data] = [:]
        func gather(_ node: Node) {
            inside.insert(node.id)
            for attachment in node.attachments where attachment.lockKeyID == nil {
                if let data = content(attachment) { files[attachment.fileName] = data }
                if attachment.kind == .markdown { files.merge(images(attachment)) { first, _ in first } }
            }
            node.children.forEach(gather)
        }
        topics.forEach(gather)
        let relationships = self.relationships.filter { inside.contains($0.fromNodeID) && inside.contains($0.toNodeID) }
        let boundaries = self.boundaries.filter { !$0.memberIDs.isEmpty && $0.memberIDs.allSatisfy(inside.contains) }
        return TopicClipboard(topics: topics, relationships: relationships, boundaries: boundaries, files: files)
    }

    /// Edits that insert a pasted `instance`: under `parentID` (appended in
    /// order), or as floating topics around `point` when `parentID` is nil.
    func pasteEdits(_ instance: TopicClipboard.Instance, into parentID: UUID?, at point: CGPoint) throws -> [MapEdit] {
        var scratch = self
        var edits: [MapEdit] = []
        func add(_ batch: [MapEdit]) throws {
            try scratch.apply(batch)
            edits += batch
        }
        for (index, topic) in instance.topics.enumerated() {
            if let parentID {
                try add(try scratch.addChildEdits(topic, to: parentID))
            } else {
                let offset = CGFloat(index) * 44
                try add(scratch.addFloatingEdits(topic, at: CGPoint(x: point.x + offset, y: point.y + offset)))
            }
        }
        for relationship in instance.relationships {
            try add([.insertRelationship(relationship, index: scratch.relationships.count)])
        }
        for boundary in instance.boundaries {
            try add([.insertBoundary(boundary, index: scratch.boundaries.count)])
        }
        return edits
    }
}
