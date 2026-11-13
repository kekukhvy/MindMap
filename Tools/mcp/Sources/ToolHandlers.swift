import CoreGraphics
import Foundation

/// The tool implementations. Edits go through the app's own model operations.
final class ToolHandlers {
    private let library: MapLibrary
    private let writer: MapWriter

    init(library: MapLibrary) {
        self.library = library
        self.writer = MapWriter(library: library)
    }

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "list_maps": return listMaps()
        case "read_map": return try readMap(args)
        case "add_topics": return try addTopics(args)
        case "rename_topic": return try renameTopic(args)
        case "move_topic": return try moveTopic(args)
        case "delete_topic": return try deleteTopic(args)
        case "read_note": return try readNote(args)
        case "write_note": return try writeNote(args)
        default: throw ToolError("Unknown tool: \(name)")
        }
    }

    // MARK: Reading

    private func listMaps() -> String {
        let rows: [[String: Any]] = library.entries().map { entry in
            var row: [String: Any] = ["map_id": entry.id, "locked": entry.isLocked, "name": library.name(of: entry) ?? entry.packageName]
            if !entry.isLocked, let loaded = try? library.load(entry) {
                row["topics"] = Outline.topicCount(loaded.map)
            }
            return row
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func readMap(_ args: [String: Any]) throws -> String {
        let loaded = try library.load(try library.resolve(try string(args, "map")))
        return Outline.render(loaded.map, name: loaded.map.title ?? loaded.map.root.text, mapID: loaded.entry.id)
    }

    // MARK: Topic edits

    private func addTopics(_ args: [String: Any]) throws -> String {
        let loaded = try library.loadForWrite(try library.resolve(try string(args, "map")))
        let parent = try uuid(args, "parent_id")
        guard loaded.map.node(withID: parent) != nil else { throw ToolError("No topic with id \(parent).") }
        guard let clipboard = TopicClipboard(plainText: try string(args, "outline")) else {
            throw ToolError("The outline has no topics.")
        }
        let instance = clipboard.instantiate()
        var map = loaded.map
        try edit { _ = try map.apply(try loaded.map.pasteEdits(instance, into: parent, at: .zero)) }
        try writer.commit(loaded, map)
        var lines: [String] = []
        instance.topics.forEach { Outline.append($0, depth: 0, to: &lines) }
        return "Added \(instance.topics.reduce(0) { $0 + $1.allIDs.count }) topics under \(parent):\n" + lines.joined(separator: "\n")
    }

    private func renameTopic(_ args: [String: Any]) throws -> String {
        let loaded = try library.loadForWrite(try library.resolve(try string(args, "map")))
        let id = try uuid(args, "topic_id")
        let text = TopicTextInput.singleLine(try string(args, "text"))
        guard !text.isEmpty else { throw ToolError("The new text is empty.") }
        var map = loaded.map
        try edit { _ = try map.apply(.tree(.rename(id: id, text: text))) }
        try writer.commit(loaded, map)
        return "Renamed \(id) to \"\(text)\"."
    }

    private func moveTopic(_ args: [String: Any]) throws -> String {
        let loaded = try library.loadForWrite(try library.resolve(try string(args, "map")))
        let id = try uuid(args, "topic_id")
        let parent = try uuid(args, "new_parent_id")
        var map = loaded.map
        try edit { _ = try map.apply(try loaded.map.reparentEdits(id, to: parent, at: args["index"] as? Int)) }
        try writer.commit(loaded, map)
        return "Moved \(id) under \(parent)."
    }

    private func deleteTopic(_ args: [String: Any]) throws -> String {
        let loaded = try library.loadForWrite(try library.resolve(try string(args, "map")))
        let id = try uuid(args, "topic_id")
        var map = loaded.map
        try edit { _ = try map.apply(try loaded.map.deleteEdits(id)) }
        try writer.commit(loaded, map)
        return "Deleted \(id) with its subtree."
    }

    // MARK: Notes

    private func readNote(_ args: [String: Any]) throws -> String {
        let loaded = try library.load(try library.resolve(try string(args, "map")))
        guard let note = try findNote(in: loaded.map, args) else { throw ToolError("The topic has no markdown note.") }
        let url = loaded.entry.packageURL.appendingPathComponent(MindMapPackage.attachmentsFolderName)
            .appendingPathComponent(note.attachment.fileName)
        guard let data = try? Data(contentsOf: url) else { throw ToolError("The note file is missing.") }
        return MarkdownNote.text(data)
    }

    private func writeNote(_ args: [String: Any]) throws -> String {
        let loaded = try library.loadForWrite(try library.resolve(try string(args, "map")))
        let text = try string(args, "text")
        var map = loaded.map
        var attachment: Attachment
        if let found = try findNote(in: loaded.map, args) {
            attachment = found.attachment
            let modified = Date()
            try edit { _ = try map.apply(try loaded.map.updateAttachmentEdits(attachment.id) { $0.modifiedAt = modified }) }
        } else {
            guard let topicID = try optionalUUID(args, "topic_id"), let node = loaded.map.node(withID: topicID) else {
                throw ToolError("Give a topic_id of an existing topic.")
            }
            let count = node.attachments.filter { $0.kind == .markdown }.count
            attachment = Attachment(kind: .markdown, title: count == 0 ? "Note" : "Note \(count + 1)")
            try edit { _ = try map.apply(try loaded.map.addAttachmentEdits(attachment, to: topicID)) }
        }
        try writer.commit(loaded, map, note: NoteFile(name: attachment.fileName, data: MarkdownNote.data(text)))
        return "Wrote note \(attachment.id) (\(text.utf8.count) bytes)."
    }

    /// The addressed markdown note: by `note_id`, else the first one of `topic_id`. nil = the topic has none.
    private func findNote(in map: MindMap, _ args: [String: Any]) throws -> (nodeID: UUID, attachment: Attachment)? {
        let found: (nodeID: UUID, attachment: Attachment)?
        if let noteID = try optionalUUID(args, "note_id") {
            guard let hit = map.attachment(withID: noteID), hit.attachment.kind == .markdown else {
                throw ToolError("No markdown note with id \(noteID).")
            }
            found = hit
        } else {
            let topicID = try uuid(args, "topic_id")
            guard let node = map.node(withID: topicID) else { throw ToolError("No topic with id \(topicID).") }
            found = node.attachments.first { $0.kind == .markdown }.map { (topicID, $0) }
        }
        if let found, found.attachment.isLocked || found.attachment.fileName.hasSuffix(LockedPackage.sealedSuffix) {
            throw ToolError("The note is locked; it is never read or written.")
        }
        guard let found, Attachment.isValidFileName(found.attachment.fileName) else { return nil }
        return found
    }

    // MARK: Arguments

    /// Runs a model operation, turning its errors into readable refusals.
    private func edit(_ body: () throws -> Void) throws {
        do { try body() } catch let error as TreeEditError {
            switch error {
            case .nodeNotFound: throw ToolError("No such topic.")
            case .cannotRemoveRoot: throw ToolError("The central topic cannot be deleted.")
            case .cannotMoveRoot: throw ToolError("The central topic cannot be moved.")
            case .invalidMoveTarget: throw ToolError("A topic cannot be moved into its own subtree.")
            default: throw ToolError("The edit was refused by the map model (\(error)).")
            }
        }
    }

    private func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String else { throw ToolError("Missing argument '\(key)'.") }
        return value
    }

    private func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let value = try optionalUUID(args, key) else { throw ToolError("Missing argument '\(key)'.") }
        return value
    }

    private func optionalUUID(_ args: [String: Any], _ key: String) throws -> UUID? {
        guard let raw = args[key] as? String else { return nil }
        guard let value = UUID(uuidString: raw) else { throw ToolError("Argument '\(key)' is not a valid id.") }
        return value
    }
}
