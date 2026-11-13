import Foundation

// Tests AC-mcp-1 ... AC-mcp-11. Run through Tools/mcp/test.sh (args: repo root, binary).

typealias Test = (name: String, run: () throws -> Void)
let road = Fixture.roadmapID
let feat = Fixture.featuresID
let toolNames: Set<String> = ["list_maps", "read_map", "add_topics", "rename_topic", "move_topic", "delete_topic",
                              "read_note", "write_note"]

func id(_ node: Node?) throws -> String {
    guard let node else { throw TestFailure("topic not found") }
    return node.id.uuidString
}

let tests: [Test] = [
    ("AC-mcp-1 initialize + tools/list return all 8 tools with schemas", {
        let client = try Fixture().client()
        let initialized = try client.request("initialize", ["protocolVersion": "2025-06-18"])
        let result = initialized["result"] as? [String: Any]
        try expect(result?["protocolVersion"] as? String == "2025-06-18", "protocolVersion not echoed")
        try expect(((result?["serverInfo"] as? [String: Any])?["name"] as? String) == "mindmap-mcp", "serverInfo")
        try expect((result?["capabilities"] as? [String: Any])?["tools"] != nil, "capabilities.tools")
        try client.notify("notifications/initialized")
        try expect(try client.request("ping")["result"] != nil, "ping")
        let tools = ((try client.request("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        try expect(Set(tools.compactMap { $0["name"] as? String }) == toolNames, "tool names \(tools.count)")
        for tool in tools {
            let schema = tool["inputSchema"] as? [String: Any]
            try expect(schema?["type"] as? String == "object" && schema?["properties"] is [String: Any], "schema of \(tool["name"] ?? "?")")
        }
    }),
    ("AC-mcp-2 list_maps counts topics", {
        let fixture = try Fixture()
        let rows = try JSONSerialization.jsonObject(with: Data(try fixture.client().call("list_maps").text.utf8)) as? [[String: Any]] ?? []
        try expect(rows.count == 2, "rows \(rows.count)")
        for mapID in [road, feat] {
            let model = try fixture.map(mapID)
            let row = rows.first { $0["map_id"] as? String == mapID }
            try expect(row?["topics"] as? Int == model.trees.reduce(0) { $0 + $1.allIDs.count }, "count of \(mapID)")
            try expect(row?["locked"] as? Bool == false, "locked flag")
        }
    }),
    ("AC-mcp-3 read_map shows ids and floating topics", {
        let fixture = try Fixture()
        let model = try fixture.map(feat)
        try expect(!model.floatingTopics.isEmpty, "sample has no floating topic")
        let text = try fixture.client().call("read_map", ["map": feat]).text
        for tree in model.trees {
            for uuid in tree.allIDs { try expect(text.contains(uuid.uuidString), "id \(uuid) missing") }
        }
        try expect(text.contains("Floating topics:"), "floating heading")
        try expect(text.contains("{note="), "note flag")
    }),
    ("AC-mcp-4 add_topics nests, makes a task, decodes", {
        let fixture = try Fixture()
        let before = try fixture.map(road)
        let reply = try fixture.client().call("add_topics", ["map": road, "parent_id": before.root.id.uuidString,
                                                             "outline": "A\n  B\n    C\n  D\n- [ ] Task"])
        try expect(!reply.isError, reply.text)
        let after = try fixture.map(road)
        let added = Array(after.root.children.dropFirst(before.root.children.count))
        try expect(added.map(\.text) == ["A", "Task"], "top level \(added.map(\.text))")
        try expect(Array(after.root.children.prefix(before.root.children.count)) == before.root.children, "old children changed")
        try expect(added[0].children.map(\.text) == ["B", "D"], "A children")
        try expect(added[0].children[0].children.map(\.text) == ["C"], "B children")
        try expect(added[1].task?.isDone == false, "Task is not a task")
        try expect(after.trees.reduce(0) { $0 + $1.allIDs.count } == before.trees.reduce(0) { $0 + $1.allIDs.count } + 5, "count")
    }),
    ("AC-mcp-5 rename_topic changes one text", {
        let fixture = try Fixture()
        let before = try fixture.map(road)
        let reply = try fixture.client().call("rename_topic", ["map": road, "topic_id": try id(before.topic("Done")), "text": "Finished"])
        try expect(!reply.isError, reply.text)
        var expected = before
        _ = try expected.apply(.tree(.rename(id: before.topic("Done")!.id, text: "Finished")))
        try expect(try fixture.map(road) == expected, "map differs from the expected rename")
        try expect(try fixture.map(road).topic("Finished") != nil, "new text missing")
    }),
    ("AC-mcp-6 move_topic moves; into own child is refused", {
        let fixture = try Fixture()
        let before = try fixture.map(road)
        let done = try id(before.topic("Done")), stage = try id(before.topic("Stage 1 — tree editor"))
        let client = try fixture.client()
        let bytes = try fixture.mapData(road)
        let refused = try client.call("move_topic", ["map": road, "topic_id": done, "new_parent_id": stage])
        try expect(refused.isError && refused.text.contains("own subtree"), "no refusal: \(refused.text)")
        try expect(try fixture.mapData(road) == bytes, "file changed by a refused move")
        let moved = try client.call("move_topic", ["map": road, "topic_id": stage, "new_parent_id": before.root.id.uuidString, "index": 0])
        try expect(!moved.isError, moved.text)
        let after = try fixture.map(road)
        try expect(after.root.children.first?.id.uuidString == stage, "not first child of root")
        try expect(after.node(withID: before.topic("Done")!.id)?.children.contains { $0.id.uuidString == stage } == false, "still under Done")
    }),
    ("AC-mcp-7 delete_topic removes subtree and relationships; central refused", {
        let fixture = try Fixture()
        let before = try fixture.map(feat)
        guard let relationship = before.relationships.first, let victim = before.node(withID: relationship.fromNodeID) else {
            throw TestFailure("sample has no relationship")
        }
        let client = try fixture.client()
        let reply = try client.call("delete_topic", ["map": feat, "topic_id": victim.id.uuidString])
        try expect(!reply.isError, reply.text)
        let after = try fixture.map(feat)
        let gone = Set(victim.allIDs)
        try expect(gone.allSatisfy { !after.contains($0) }, "subtree remains")
        try expect(after.relationships.allSatisfy { !gone.contains($0.fromNodeID) && !gone.contains($0.toNodeID) }, "relationship remains")
        try expect(after.relationships.count < before.relationships.count, "relationship count")
        let bytes = try fixture.mapData(feat)
        let central = try client.call("delete_topic", ["map": feat, "topic_id": after.root.id.uuidString])
        try expect(central.isError && (try fixture.mapData(feat)) == bytes, "central topic deleted")
    }),
    ("AC-mcp-8 write_note / read_note round trip, locked note refused", {
        let fixture = try Fixture()
        let client = try fixture.client()
        let done = try id(try fixture.map(road).topic("Done"))
        let text = "# Hello\n\n- from Claude\n"
        let created = try client.call("write_note", ["map": road, "topic_id": done, "text": text])
        try expect(!created.isError, created.text)
        let note = try fixture.map(road).topic("Done")?.attachments.first
        try expect(note?.kind == .markdown && note?.fileName.hasSuffix(".md") == true, "attachment kind")
        let file = fixture.package(road).appendingPathComponent("attachments/\(note?.fileName ?? "-")")
        try expect(try String(contentsOf: file, encoding: .utf8) == text, "note file content")
        try expect(try client.call("read_note", ["map": road, "topic_id": done]).text == text, "read_note")
        // Existing note: replaced in place, same attachment.
        let rootID = try fixture.map(road).root.id.uuidString
        let replaced = try client.call("write_note", ["map": road, "topic_id": rootID, "text": "new"])
        try expect(!replaced.isError && (try client.call("read_note", ["map": road, "topic_id": rootID])).text == "new", "replace")
        try expect(fixture.backupNames(road).contains { $0.contains("-note-") }, "old note file not backed up")
        // Locked note.
        var model = try fixture.map(road)
        let lockedID = model.root.attachments[0].id
        _ = try model.apply(try model.updateAttachmentEdits(lockedID) { $0.lockKeyID = UUID() })
        try fixture.save(model, road)
        let bytes = try fixture.mapData(road)
        let client2 = try fixture.client()
        try expect(try client2.call("read_note", ["map": road, "topic_id": rootID]).isError, "locked read")
        try expect(try client2.call("write_note", ["map": road, "note_id": lockedID.uuidString, "text": "x"]).isError, "locked write")
        try expect(try fixture.mapData(road) == bytes, "map changed by a refused note write")
    }),
    ("AC-mcp-9 changed map.json between read and write is refused", {
        let fixture = try Fixture()
        let client = try fixture.client()
        let rootID = try fixture.map(road).root.id.uuidString
        _ = try client.call("read_map", ["map": road])
        let future = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fixture.mapURL(road).path)
        let bytes = try fixture.mapData(road)
        let refused = try client.call("add_topics", ["map": road, "parent_id": rootID, "outline": "X"])
        try expect(refused.isError && refused.text.contains("Read it again"), "not refused: \(refused.text)")
        try expect(try fixture.mapData(road) == bytes, "file written despite the refusal")
        _ = try client.call("read_map", ["map": road])
        try expect(!(try client.call("add_topics", ["map": road, "parent_id": rootID, "outline": "X"])).isError, "retry after read")
    }),
    ("AC-mcp-10 backup written, only 20 kept", {
        let fixture = try Fixture()
        let client = try fixture.client()
        let original = try fixture.mapData(road)
        let target = try id(try fixture.map(road).topic("Done"))
        _ = try client.call("rename_topic", ["map": road, "topic_id": target, "text": "Done first"])
        let firstBackup = try Data(contentsOf: fixture.backups.appendingPathComponent(road).appendingPathComponent(fixture.backupNames(road).first ?? "none"))
        try expect(firstBackup == original, "first backup is not the old map.json byte for byte")
        for n in 0..<25 { _ = try client.call("rename_topic", ["map": road, "topic_id": target, "text": "Done \(n)"]) }
        let names = fixture.backupNames(road).filter { $0.hasSuffix("-map.json") }
        try expect(names.count == 20, "backups \(names.count)")
        let newest = try Data(contentsOf: fixture.backups.appendingPathComponent(road).appendingPathComponent(names.last!))
        try expect(try MindMapPackage.decode(newest).topic("Done 23") != nil, "newest backup is the state before the last write")
        try expect(original != (try fixture.mapData(road)), "map unchanged")
    }),
    ("AC-mcp-11 locked map / newer formatVersion / read-only refused", {
        let fixture = try Fixture()
        let rootID = try fixture.map(road).root.id.uuidString
        // Locked map: lock.json present.
        try LockHeader(keyID: UUID()).encoded().write(to: fixture.package(road).appendingPathComponent("lock.json"))
        // Newer format.
        var json = try JSONSerialization.jsonObject(with: try fixture.mapData(feat)) as? [String: Any] ?? [:]
        json["formatVersion"] = MindMap.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.mapURL(feat))
        let client = try fixture.client()
        let rows = try JSONSerialization.jsonObject(with: Data(try client.call("list_maps").text.utf8)) as? [[String: Any]] ?? []
        try expect(rows.first { $0["map_id"] as? String == road }?["locked"] as? Bool == true, "locked flag")
        let roadBytes = try fixture.mapData(road), featBytes = try fixture.mapData(feat)
        for (map, args) in [(road, ["parent_id": rootID, "outline": "X"]), (feat, ["parent_id": rootID, "outline": "X"])] {
            let reply = try client.call("add_topics", ["map": map].merging(args) { $1 })
            try expect(reply.isError, "write to \(map) not refused")
            try expect(try client.call("read_map", ["map": map]).isError, "read of \(map) not refused")
        }
        try expect(try fixture.mapData(road) == roadBytes && (try fixture.mapData(feat)) == featBytes, "files changed")
        // Read-only map (extra).
        let second = try Fixture()
        var model = try second.map(road)
        _ = try model.apply(.setReadOnly(true))
        try second.save(model, road)
        try expect(try second.client().call("rename_topic", ["map": road, "topic_id": model.root.id.uuidString, "text": "x"]).isError, "read-only")
    }),
]

var failed = 0
for test in tests {
    do {
        try test.run()
        print("PASS \(test.name)")
    } catch let error as TestFailure {
        failed += 1
        print("FAIL \(test.name): \(error.message)")
    } catch {
        failed += 1
        print("FAIL \(test.name): \(error)")
    }
}
print(failed == 0 ? "all \(tests.count) passed" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
