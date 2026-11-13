import Foundation

/// The eight tools with their JSON Schemas (`tools/list`).
enum ToolCatalog {
    private static let mapHelp = "Map id (folder id from list_maps) or its exact name."

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }

    static let tools: [[String: Any]] = [
        tool("list_maps", "List the mind maps: name, map id, topic count, locked flag.", [:], required: []),
        tool("read_map", "Read a map as an indented outline with topic ids and flags (note, task, link).",
             ["map": string(mapHelp)], required: ["map"]),
        tool("add_topics",
             "Add topics under a parent from indented outline text (2 spaces or a tab per level; '- [ ] ' makes a task).",
             ["map": string(mapHelp), "parent_id": string("Topic id of the parent."),
              "outline": string("Indented outline, one topic per line.")],
             required: ["map", "parent_id", "outline"]),
        tool("rename_topic", "Change the text of a topic.",
             ["map": string(mapHelp), "topic_id": string("Topic id."), "text": string("New text.")],
             required: ["map", "topic_id", "text"]),
        tool("move_topic", "Move a topic (with its subtree) under another parent.",
             ["map": string(mapHelp), "topic_id": string("Topic to move."),
              "new_parent_id": string("New parent topic id."),
              "index": ["type": "integer", "description": "Position among the new parent's children (default: last)."]],
             required: ["map", "topic_id", "new_parent_id"]),
        tool("delete_topic", "Delete a topic and its subtree, with relationships and boundaries that refer to it. The central topic cannot be deleted.",
             ["map": string(mapHelp), "topic_id": string("Topic id.")], required: ["map", "topic_id"]),
        tool("read_note", "Read the markdown note of a topic (by note id, or the topic's first markdown note).",
             ["map": string(mapHelp), "topic_id": string("Topic id (optional when note_id is given)."),
              "note_id": string("Attachment id of the note (optional).")],
             required: ["map"]),
        tool("write_note", "Write the markdown note of a topic (by note id, or the topic's first markdown note); creates the note when the topic has none.",
             ["map": string(mapHelp), "topic_id": string("Topic id (optional when note_id is given)."),
              "note_id": string("Attachment id of the note (optional)."),
              "text": string("Markdown text of the note.")],
             required: ["map", "text"]),
    ]
}
