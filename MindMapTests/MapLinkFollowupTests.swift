import Foundation
import Testing
@testable import MindMap

/// WP10 leftovers: dimmed icon for a map link whose file is gone; undoing
/// a "New Map…" link puts the untouched new file away (redo restores it).
@MainActor
@Suite(.serialized)
struct MapLinkFollowupTests {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MapLinkFollowup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func editor(in folder: URL) throws -> (EditorController, UUID, UndoManager) {
        let topic = Node(text: "Roadmap")
        let model = MindMapModel(map: MindMap(root: Node(text: "Central", children: [topic])))
        let documentURL = folder.appendingPathComponent("Main.mindmap")
        try MapLinkTests.writeMap(model.map, to: documentURL)
        let editor = EditorController(model: model)
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.documentURL = documentURL
        return (editor, topic.id, undo)
    }

    @Test func missingMapFileDimsTheIconUntilItIsBack() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (editor, topic, _) = try editor(in: folder)
        let target = folder.appendingPathComponent("Other.mindmap")
        try MapLinkTests.writeMap(MindMap(root: Node(text: "Other")), to: target)
        editor.linkMap(at: target, to: topic)
        editor.refreshMissingMapLinks()
        #expect(editor.missingMapLinks.isEmpty)
        #expect(editor.scene.nodes[topic]?.link?.isBroken == false)

        // Gone for good (a moved file would still be found by its bookmark).
        try FileManager.default.removeItem(at: target)
        editor.refreshMissingMapLinks()
        #expect(editor.missingMapLinks == [topic])
        let summary = try #require(editor.scene.nodes[topic]?.link)
        #expect(summary.kind == .map && summary.isBroken)
        #expect(summary.tooltip.hasPrefix(LinkSummary.missingMapMessage))
        #expect(summary.iconHelp.hasSuffix("Click to locate it"))
        // Go to on it: the Locate… alert (and it stays dimmed).
        editor.openMapLink(of: topic)
        #expect(editor.mapLinkProblem != nil)
        #expect(editor.missingMapLinks == [topic])

        // The file is back (e.g. restored from the Trash): icon normal again.
        try MapLinkTests.writeMap(MindMap(root: Node(text: "Other")), to: target)
        editor.refreshMissingMapLinks()
        #expect(editor.missingMapLinks.isEmpty)
        #expect(editor.scene.nodes[topic]?.link?.isBroken == false)
    }

    @Test func undoOfNewMapLinkKeepsAnEditedFile() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (editor, topic, undo) = try editor(in: folder)
        let url = try editor.createLinkedMap(for: topic)
        #expect(undo.undoActionName == "Add Link")
        // Someone opened and edited the new map since.
        let json = url.appendingPathComponent(MindMapPackage.mapFileName)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: json.path)
        undo.undo()
        #expect(editor.model.map.link(of: topic) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        undo.redo()
        #expect(editor.model.map.link(of: topic)?.mapReference != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func putAwaySkipsOpenMaps() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try MapFiles.createMap(named: "Open One", nextTo: folder.appendingPathComponent("Main.mindmap"))
        let stamp = CreatedMapFiles.stamp(of: url)
        #expect(CreatedMapFiles.putAwayIfUntouched(url, stamp: stamp, isOpen: { _ in true }) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let held = try #require(CreatedMapFiles.putAwayIfUntouched(url, stamp: stamp, isOpen: { _ in false }))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        CreatedMapFiles.restore(held, to: url)
        #expect(try MapFiles.readMap(at: url).root.text == "Open One")
    }
}
