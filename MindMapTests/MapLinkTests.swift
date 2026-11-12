import Foundation
import Testing
@testable import MindMap

/// WP10 map links: model + undo, JSON compatibility (unknown kinds kept),
/// relative paths, resolution (relative → bookmark → missing), "New Map…",
/// Go to / Locate in the editor.
@MainActor
struct MapLinkTests {
    private static let folder = URL(fileURLWithPath: "/maps/Work")
    private static let documentURL = folder.appendingPathComponent("Main.mindmap")

    private static func makeModel() -> (model: MindMapModel, topic: UUID) {
        let topic = Node(text: "Q3 Plan")
        return (MindMapModel(map: MindMap(root: Node(text: "Central", children: [topic]))), topic.id)
    }

    // MARK: Model + undo

    @Test func setEditRemoveMapLinkAreSingleUndoSteps() throws {
        let (model, topic) = Self.makeModel()
        let undo = UndoTests.makeUndoManager()
        let first = MapReference(relativePath: "Plan.mindmap", bookmark: Data([1, 2]))
        var second = first
        second.targetTopicID = UUID()
        #expect(model.setLink(.map(first), for: topic, undoManager: undo))
        #expect(undo.undoActionName == "Add Link")
        #expect(model.setLink(.map(second), for: topic, undoManager: undo))
        #expect(undo.undoActionName == "Edit Link")
        #expect(model.removeLink(from: topic, undoManager: undo))
        undo.undo()
        #expect(model.map.link(of: topic) == .map(second))
        undo.undo()
        #expect(model.map.link(of: topic) == .map(first))
        #expect(model.map.resolvedLink(of: topic) == .map(first))
        undo.undo()
        #expect(model.map.link(of: topic) == nil)
        // A reference without path and bookmark is rejected.
        #expect(!model.setLink(.map(MapReference(relativePath: nil, displayName: "X")), for: topic, undoManager: undo))
    }

    @Test func displayNameDefaultsToFileName() {
        #expect(MapReference(relativePath: "../Shared/Ideas.mindmap").displayName == "Ideas")
        #expect(MapReference(relativePath: "Plan.mindmap").pathDescription == "Plan.mindmap")
        #expect(MapReference(relativePath: nil, bookmark: Data([1]), displayName: "Plan").pathDescription
                == "Plan.mindmap")
    }

    // MARK: JSON

    @Test func mapLinkJSONRoundTripAndShape() throws {
        let target = UUID()
        var node = Node(text: "T")
        node.link = .map(MapReference(relativePath: "Sub/Plan.mindmap", bookmark: Data([0xCA, 0xFE]),
                                      displayName: "Plan", targetTopicID: target))
        let data = try JSONEncoder().encode(node)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""kind":"map""#) && json.contains(#""path":"Sub\/Plan.mindmap""#))
        #expect(json.contains(#""name":"Plan""#) && json.contains(#""bookmark":"yv4=""#))
        #expect(json.contains(#""topicID":"\#(target.uuidString)""#))
        #expect(try JSONDecoder().decode(Node.self, from: data) == node)
        // Minimal (older writer / no bookmark): name from the path.
        let minimal = #"{"id":"\#(UUID().uuidString)","link":{"kind":"map","path":"A.mindmap"}}"#
        let decoded = try JSONDecoder().decode(Node.self, from: Data(minimal.utf8))
        #expect(decoded.link == .map(MapReference(relativePath: "A.mindmap", displayName: "A")))
    }

    @Test func unknownLinkKindsArePreservedButAreNoLink() throws {
        let id = UUID()
        let future = #"{"kind":"file","path":"a.pdf","extra":{"n":[1,true,null,"x"]}}"#
        let json = #"{"id":"\#(id.uuidString)","text":"T","link":\#(future)}"#
        let node = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        guard case let .unknown(raw)? = node.link else {
            Issue.record("expected an unknown link")
            return
        }
        #expect(raw.kind == "file")
        let map = MindMap(root: node)
        #expect(map.link(of: id) == nil && map.resolvedLink(of: id) == nil)
        #expect(LinkSummary(of: node, in: map) == nil)
        // Saved back verbatim.
        let reencoded = try JSONDecoder().decode(Node.self, from: try JSONEncoder().encode(node))
        #expect(reencoded.link == node.link)
        let text = String(decoding: try JSONEncoder().encode(node), as: UTF8.self)
        #expect(text.contains(#""kind":"file""#) && text.contains(#""extra""#))
        // A map link with nothing to find the file with is kept as unknown too.
        let empty = #"{"id":"\#(UUID().uuidString)","link":{"kind":"map","name":"X"}}"#
        #expect(try JSONDecoder().decode(Node.self, from: Data(empty.utf8)).link?.isKnown == false)
        // Adding a real link replaces the unknown one (one undo step).
        let model = MindMapModel(map: map)
        let undo = UndoTests.makeUndoManager()
        #expect(model.setLink(.web(URL(string: "https://a.com")!), for: id, undoManager: undo))
        undo.undo()
        #expect(model.map.node(withID: id)?.link == node.link)
    }

    // MARK: Paths

    @Test func relativePaths() {
        let doc = Self.documentURL
        #expect(MapPaths.relativePath(from: doc, to: Self.folder.appendingPathComponent("B.mindmap")) == "B.mindmap")
        #expect(MapPaths.relativePath(from: doc, to: URL(fileURLWithPath: "/maps/Work/Sub/C.mindmap")) == "Sub/C.mindmap")
        #expect(MapPaths.relativePath(from: doc, to: URL(fileURLWithPath: "/maps/Home/D.mindmap")) == "../Home/D.mindmap")
        #expect(MapPaths.relativePath(from: doc, to: URL(fileURLWithPath: "/other/E.mindmap")) == "../../other/E.mindmap")
        #expect(MapPaths.relativePath(from: doc, to: URL(string: "https://a.com/x")!) == nil)
        for (path, normalized) in [("B.mindmap", "B.mindmap"), ("Sub/C.mindmap", "Sub/C.mindmap"),
                                   ("../Home/D.mindmap", "../Home/D.mindmap"), ("./B.mindmap", "B.mindmap")] {
            let url = MapPaths.resolve(path, from: doc)
            #expect(url.flatMap { MapPaths.relativePath(from: doc, to: $0) } == normalized)
        }
        #expect(MapPaths.resolve("/abs/x.mindmap", from: doc) == nil)
        #expect(MapPaths.resolve("", from: doc) == nil)
    }

    @Test func newMapFileNames() {
        #expect(MapPaths.fileNameBase(forTopic: "Q3 / Plan: v2") == "Q3 - Plan- v2")
        #expect(MapPaths.fileNameBase(forTopic: "  ..hidden\nsecond line") == "hidden")
        #expect(MapPaths.fileNameBase(forTopic: "   ") == "Untitled")
        #expect(MapPaths.fileNameBase(forTopic: String(repeating: "a", count: 200)).count == 80)
    }

    // MARK: Resolution

    private func resolver(_ coder: FakeBookmarkCoder, existing: Set<String>) -> MapLinkResolver {
        MapLinkResolver(coder: coder, exists: { existing.contains($0.standardizedFileURL.path) })
    }

    @Test func resolvesRelativePathFirst() throws {
        let coder = FakeBookmarkCoder()
        let sibling = Self.folder.appendingPathComponent("B.mindmap")
        let elsewhere = URL(fileURLWithPath: "/old/B.mindmap")
        let r = resolver(coder, existing: [sibling.path, elsewhere.path])
        // The bookmark points elsewhere: the relative path wins.
        let reference = MapReference(relativePath: "B.mindmap", bookmark: try coder.bookmark(for: elsewhere))
        #expect(r.resolve(reference, documentURL: Self.documentURL) == .found(sibling, refreshed: nil))
        // Same file through the bookmark: its URL (security scope) is used.
        let same = MapReference(relativePath: "B.mindmap", bookmark: try coder.bookmark(for: sibling))
        guard case let .found(url, nil) = r.resolve(same, documentURL: Self.documentURL) else {
            Issue.record("not found")
            return
        }
        #expect(url.path == sibling.path)
    }

    @Test func movedFileIsFoundByBookmarkAndRefreshed() throws {
        let coder = FakeBookmarkCoder()
        let moved = URL(fileURLWithPath: "/maps/Work/Archive/Plan 2024.mindmap")
        let r = resolver(coder, existing: [moved.path])
        let target = UUID()
        coder.stale = true
        let reference = MapReference(relativePath: "Plan.mindmap", bookmark: try coder.bookmark(for: moved),
                                     displayName: "Plan", targetTopicID: target)
        let created = coder.created
        guard case let .found(url, refreshed?) = r.resolve(reference, documentURL: Self.documentURL) else {
            Issue.record("expected a refreshed reference")
            return
        }
        #expect(url.path == moved.path)
        #expect(refreshed.relativePath == "Archive/Plan 2024.mindmap")
        #expect(refreshed.displayName == "Plan 2024" && refreshed.targetTopicID == target)
        #expect(coder.created == created + 1) // stale bookmark re-created
    }

    @Test func missingWhenNeitherPathNorBookmarkResolve() throws {
        let coder = FakeBookmarkCoder()
        let r = resolver(coder, existing: [])
        let reference = MapReference(relativePath: "B.mindmap", bookmark: try coder.bookmark(for: URL(fileURLWithPath: "/x.mindmap")))
        #expect(r.resolve(reference, documentURL: Self.documentURL) == .missing)
        coder.broken = true
        #expect(r.resolve(reference, documentURL: nil) == .missing)
    }

    @Test func unsavedDocumentStoresBookmarkThenRelativePathOnSave() throws {
        let coder = FakeBookmarkCoder()
        let target = Self.folder.appendingPathComponent("Sub/B.mindmap")
        let r = resolver(coder, existing: [target.path])
        let reference = r.reference(to: target, from: nil)
        #expect(reference.relativePath == nil && reference.bookmark != nil && reference.displayName == "B")
        #expect(r.resolve(reference, documentURL: nil) == .found(target, refreshed: nil))
        let id = UUID()
        let updates = r.relativePathUpdates(for: [(id, reference)], documentURL: Self.documentURL)
        #expect(updates[id]?.relativePath == "Sub/B.mindmap")
        // Already correct: nothing to update.
        #expect(r.relativePathUpdates(for: [(id, updates[id]!)], documentURL: Self.documentURL).isEmpty)
    }

    // MARK: Files on disk

    private static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MapLinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeMap(_ map: MindMap, to url: URL) throws {
        try MindMapPackage.fileWrapper(for: map).write(to: url, options: .atomic, originalContentsURL: nil)
    }

    @Test func newMapIsCreatedNextToDocumentAndLinked() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let documentURL = folder.appendingPathComponent("Main.mindmap")
        let (model, topic) = Self.makeModel()
        try Self.writeMap(model.map, to: documentURL)
        let editor = EditorController(model: model)
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.documentURL = documentURL

        let url = try editor.createLinkedMap(for: topic)
        #expect(url.lastPathComponent == "Q3 Plan.mindmap")
        #expect(try MapFiles.readMap(at: url).root.text == "Q3 Plan")
        #expect(undo.undoActionName == "Add Link")
        let reference = try #require(model.map.link(of: topic)?.mapReference)
        #expect(reference.relativePath == "Q3 Plan.mindmap" && reference.displayName == "Q3 Plan")
        #expect(reference.bookmark != nil)
        #expect(editor.resolvedMapURL(of: topic).map(LaunchEnvironment.key) == LaunchEnvironment.key(url))
        // Name taken: "Q3 Plan 2".
        #expect(try MapFiles.createMap(named: "Q3 Plan", nextTo: documentURL).lastPathComponent == "Q3 Plan 2.mindmap")
        // Undo removes the link, the file stays.
        undo.undo()
        #expect(model.map.link(of: topic) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Never saved: no folder to create it in (the UI shows a save panel).
        editor.documentURL = nil
        #expect(throws: (any Error).self) { try editor.createLinkedMap(for: topic) }
    }

    @Test func topicsOfAnotherMapAreListed() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let deep = Node(text: "Deep")
        let other = MindMap(root: Node(text: "Other", children: [Node(text: "Folded", isCollapsed: true, children: [deep])]))
        let url = folder.appendingPathComponent("Other.mindmap")
        try Self.writeMap(other, to: url)
        let topics = try MapFiles.topics(at: url)
        #expect(topics.map(\.text) == ["Other", "Folded", "Deep"])
        #expect(topics.last?.id == deep.id && topics.last?.breadcrumb == "Other › Folded")
        #expect(throws: (any Error).self) { try MapFiles.topics(at: folder.appendingPathComponent("None.mindmap")) }
    }

    @Test func systemBookmarkFindsMovedMap() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let documentURL = folder.appendingPathComponent("Main.mindmap")
        try Self.writeMap(MindMap(), to: documentURL)
        let original = folder.appendingPathComponent("Plan.mindmap")
        try Self.writeMap(MindMap(root: Node(text: "Plan")), to: original)
        let resolver = MapLinkResolver()
        let reference = resolver.reference(to: original, from: documentURL)
        #expect(reference.relativePath == "Plan.mindmap")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent("Archive/Plan.mindmap")
        try FileManager.default.moveItem(at: original, to: moved)
        guard case let .found(url, refreshed?) = resolver.resolve(reference, documentURL: documentURL) else {
            Issue.record("moved map not found through its bookmark")
            return
        }
        #expect(LaunchEnvironment.key(url) == LaunchEnvironment.key(moved))
        #expect(refreshed.relativePath == "Archive/Plan.mindmap")
        try FileManager.default.removeItem(at: moved)
        #expect(resolver.resolve(refreshed, documentURL: documentURL) == .missing)
    }

    // MARK: Editor

    @Test func goToOpensMapAtTopicOrReportsMissingThenLocateRelinks() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let documentURL = folder.appendingPathComponent("Main.mindmap")
        let (model, topic) = Self.makeModel()
        try Self.writeMap(model.map, to: documentURL)
        let planURL = folder.appendingPathComponent("Plan.mindmap")
        try Self.writeMap(MindMap(root: Node(text: "Plan")), to: planURL)
        let editor = EditorController(model: model)
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.documentURL = documentURL
        var opened: [(URL, UUID?)] = []
        editor.mapOpener = { url, topicID, completion in
            opened.append((url, topicID))
            completion(nil)
        }
        let target = UUID()
        #expect(editor.linkMap(at: planURL, to: topic, targetTopicID: target))

        editor.goToLink(of: topic)
        #expect(opened.count == 1)
        #expect(opened.first.map { LaunchEnvironment.key($0.0) } == LaunchEnvironment.key(planURL))
        #expect(opened.first?.1 == target)
        #expect(editor.mapLinkProblem == nil && editor.selectedID == topic)

        // Missing file: alert with Locate…, nothing opened.
        let moved = folder.appendingPathComponent("Renamed.mindmap")
        try FileManager.default.moveItem(at: planURL, to: moved)
        try FileManager.default.removeItem(at: moved)
        editor.goToLink(of: topic)
        #expect(opened.count == 1)
        #expect(editor.mapLinkProblem?.nodeID == topic)
        #expect(editor.resolvedMapURL(of: topic) == nil)

        // Locate…: the picked file becomes the link's file (one undo step).
        let replacement = folder.appendingPathComponent("Plan v2.mindmap")
        try Self.writeMap(MindMap(root: Node(text: "Plan v2")), to: replacement)
        editor.beginLocateMap(topic)
        #expect(editor.isMapLocatorPresented && editor.mapLinkProblem == nil)
        editor.finishLocateMap(.success(replacement))
        #expect(undo.undoActionName == "Edit Link")
        let reference = try #require(model.map.link(of: topic)?.mapReference)
        #expect(reference.relativePath == "Plan v2.mindmap" && reference.targetTopicID == target)
        editor.goToLink(of: topic)
        #expect(opened.count == 2)

        // A failure reported by the opener is shown.
        editor.mapOpener = { _, _, completion in completion("No permission.") }
        editor.goToLink(of: topic)
        #expect(editor.mapLinkProblem?.message.contains("No permission.") == true)
    }

    @Test func linkingBeforeFirstSaveGetsRelativePathWhenSaved() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let planURL = folder.appendingPathComponent("Plan.mindmap")
        try Self.writeMap(MindMap(root: Node(text: "Plan")), to: planURL)
        let (model, topic) = Self.makeModel()
        let editor = EditorController(model: model)
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        #expect(editor.linkMap(at: planURL, to: topic))
        #expect(model.map.link(of: topic)?.mapReference?.relativePath == nil)
        #expect(editor.resolvedMapURL(of: topic) != nil)
        // Saved next to it: the path is filled in silently (no undo step).
        editor.documentURL = folder.appendingPathComponent("Untitled.mindmap")
        #expect(model.map.link(of: topic)?.mapReference?.relativePath == "Plan.mindmap")
        #expect(undo.undoActionName == "Add Link")
    }

    @Test func mapLinkIconAndSize() throws {
        var node = Node(text: "Plan")
        node.link = .map(MapReference(relativePath: "Plans/Q3.mindmap", targetTopicID: UUID()))
        let map = MindMap(root: Node(text: "Root", children: [node]))
        let summary = try #require(LinkSummary(of: node, in: map))
        #expect(summary.kind == .map && summary.systemImage == "map" && !summary.isBroken)
        #expect(summary.tooltip.contains("Q3") && summary.tooltip.contains("Plans/Q3.mindmap"))
        let editor = EditorController(model: MindMapModel(map: map))
        let info = try #require(editor.scene.nodes[node.id])
        #expect(info.link?.kind == .map)
        var unlinked = map
        _ = try unlinked.apply(try map.setLinkEdits(nil, for: node.id))
        let plain = EditorController(model: MindMapModel(map: unlinked))
        #expect(editor.scene.layout.frames[node.id]!.width > plain.scene.layout.frames[node.id]!.width)
    }
}
