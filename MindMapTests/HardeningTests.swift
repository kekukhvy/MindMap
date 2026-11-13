import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MindMap

/// WP3: undo/redo for every model operation family, dirty-state after a
/// save snapshot, boundary cleanup on moves, package round-trip with
/// attachments, legacy JSON, edge cases and layout performance.
struct UndoEveryOperationTests {
    /// Fixture: root(a(a1, a2), b), floating f, relationship a1->b,
    /// boundary around a1 (+ sibling a2).
    private struct Fixture {
        let model: MindMapModel
        let undo = UndoTests.makeUndoManager()
        let a = UUID(), a1 = UUID(), a2 = UUID(), b = UUID(), f = UUID()
        let relationship: UUID
        let boundary: UUID

        init() {
            let tree = Node(text: "r", layoutStyle: .rightMap, children: [
                Node(id: a, text: "a", children: [Node(id: a1, text: "a1"), Node(id: a2, text: "a2")]),
                Node(id: b, text: "b")
            ])
            let rel = Relationship(from: a1, to: b, label: "dep")
            let bnd = Boundary(nodeID: a1, siblingIDs: [a2], label: "grp")
            relationship = rel.id
            boundary = bnd.id
            model = MindMapModel(map: MindMap(
                root: tree, floatingTopics: [FloatingTopic(node: Node(id: f, text: "f"), position: CGPoint(x: 0, y: 300))],
                relationships: [rel], boundaries: [bnd]))
        }
    }

    private typealias Operation = (name: String, run: (Fixture) -> Bool)

    private static let operations: [Operation] = [
        ("addChild", { $0.model.addChild(to: $0.a, text: "n", undoManager: $0.undo) != nil }),
        ("addSibling", { $0.model.addSibling(after: $0.a1, text: "n", undoManager: $0.undo) != nil }),
        ("addChildToFloating", { $0.model.addChild(to: $0.f, undoManager: $0.undo) != nil }),
        ("delete", { $0.model.delete($0.a, undoManager: $0.undo) }),
        ("deleteFloating", { $0.model.delete($0.f, undoManager: $0.undo) }),
        ("reparent", { $0.model.reparent($0.a1, to: $0.b, undoManager: $0.undo) }),
        ("reorder", { $0.model.reparent($0.a2, to: $0.a, at: 0, undoManager: $0.undo) }),
        ("collapse", { $0.model.toggleCollapse($0.a, undoManager: $0.undo) }),
        ("rename", { $0.model.rename($0.b, to: "B", undoManager: $0.undo) }),
        ("renameToEmpty", { $0.model.rename($0.b, to: "", undoManager: $0.undo) }),
        ("addFloating", { $0.model.addFloating(at: CGPoint(x: 5, y: 5), undoManager: $0.undo) != nil }),
        ("moveFloating", { $0.model.moveFloating($0.f, to: CGPoint(x: 9, y: 9), undoManager: $0.undo) }),
        ("detach", { $0.model.detach($0.a1, to: CGPoint(x: 50, y: 50), undoManager: $0.undo) }),
        ("attach", { $0.model.reparent($0.f, to: $0.b, undoManager: $0.undo) }),
        ("color", { $0.model.setColor($0.a, to: .red, undoManager: $0.undo) }),
        ("customColorBranch", { $0.model.setCustomColor("#123456", for: $0.a, wholeBranch: true, undoManager: $0.undo) }),
        ("layoutStyle", { $0.model.setLayoutStyle(.treeDown, for: $0.a, undoManager: $0.undo) }),
        ("shapeBranch", { $0.model.setShape(.capsule, for: $0.a, wholeBranch: true, undoManager: $0.undo) }),
        ("border", { $0.model.setBorderStyle(.dashed, for: $0.b, undoManager: $0.undo) }),
        ("connector", { $0.model.setConnectorStyle(.elbow, for: $0.a, undoManager: $0.undo) }),
        ("lineWidth", { $0.model.setLineWidth(3, for: $0.a, undoManager: $0.undo) }),
        ("lineDash", { $0.model.setLineDash(.dotted, for: $0.a, undoManager: $0.undo) }),
        ("theme", { $0.model.setTheme(.mono(hex: "#000000"), undoManager: $0.undo) }),
        ("addRelationship", { $0.model.addRelationship(from: $0.a, to: $0.f, undoManager: $0.undo) != nil }),
        ("relabelRelationship", { $0.model.relabelRelationship($0.relationship, to: nil, undoManager: $0.undo) }),
        ("relationshipStyle", {
            $0.model.setRelationshipStyle(RelationshipStyle(path: .straight, endArrow: .diamond),
                                          for: $0.relationship, undoManager: $0.undo)
        }),
        ("relationshipCurve", {
            $0.model.setRelationshipControlOffsets($0.relationship, from: CGVector(dx: 1, dy: 2),
                                                   to: CGVector(dx: 3, dy: 4), undoManager: $0.undo)
        }),
        ("removeRelationship", { $0.model.removeRelationship($0.relationship, undoManager: $0.undo) }),
        ("addBoundary", { $0.model.addBoundary(around: $0.b, label: "x", undoManager: $0.undo) != nil }),
        ("updateBoundary", { $0.model.updateBoundary($0.boundary, label: nil, colorHex: "#FF0000", undoManager: $0.undo) }),
        ("removeBoundary", { $0.model.removeBoundary($0.boundary, undoManager: $0.undo) })
    ]

    @Test(arguments: operations.map(\.name))
    func undoRestoresAndRedoReapplies(_ name: String) throws {
        let operation = try #require(Self.operations.first { $0.name == name })
        let fixture = Fixture()
        let before = fixture.model.map
        #expect(operation.run(fixture), "\(name) failed")
        let after = fixture.model.map
        #expect(after != before, "\(name) changed nothing")
        #expect(fixture.undo.canUndo)
        fixture.undo.undo()
        #expect(fixture.model.map == before, "\(name) undo")
        #expect(!fixture.undo.canUndo, "\(name) must be a single undo step")
        fixture.undo.redo()
        #expect(fixture.model.map == after, "\(name) redo")
    }

    @Test func invalidOperationsRegisterNothing() {
        let fixture = Fixture()
        let undo = fixture.undo
        #expect(!fixture.model.delete(fixture.model.root.id, undoManager: undo))
        #expect(!fixture.model.reparent(fixture.a, to: fixture.a1, undoManager: undo))
        #expect(!fixture.model.detach(fixture.model.root.id, to: .zero, undoManager: undo))
        #expect(fixture.model.addRelationship(from: fixture.a, to: fixture.a, undoManager: undo) == nil)
        #expect(!fixture.model.rename(fixture.b, to: "b", undoManager: undo))
        #expect(!fixture.model.toggleCollapse(UUID(), undoManager: undo))
        #expect(!undo.canUndo)
    }

    @Test func deleteCleansRelationshipsBoundariesAndUndoRestores() {
        let fixture = Fixture()
        let before = fixture.model.map
        #expect(fixture.model.delete(fixture.a, undoManager: fixture.undo))
        #expect(fixture.model.map.relationships.isEmpty)
        #expect(fixture.model.map.boundaries.isEmpty)
        fixture.undo.undo()
        #expect(fixture.model.map == before)
    }

    /// Members are arbitrary topics: moving one anywhere keeps it a member
    /// (the outline follows it); no extra undo edits.
    @Test func movingAMemberKeepsItInTheBoundary() {
        let fixture = Fixture()
        #expect(fixture.model.reparent(fixture.a2, to: fixture.b, undoManager: fixture.undo))
        #expect(fixture.model.map.boundaries.first?.memberIDs == [fixture.a1, fixture.a2])
        fixture.undo.undo()

        #expect(fixture.model.detach(fixture.a1, to: .zero, undoManager: fixture.undo))
        #expect(fixture.model.map.boundaries.first?.memberIDs == [fixture.a1, fixture.a2])
        #expect(fixture.model.map.relationships.count == 1) // both ends still exist
        fixture.undo.undo()

        // Deleting one member shrinks it; deleting the last removes it.
        #expect(fixture.model.delete(fixture.a2, undoManager: fixture.undo))
        #expect(fixture.model.map.boundaries.first?.memberIDs == [fixture.a1])
        #expect(fixture.model.delete(fixture.a1, undoManager: fixture.undo))
        #expect(fixture.model.map.boundaries.isEmpty)
        fixture.undo.undo()
        fixture.undo.undo()
        #expect(fixture.model.map.boundaries.first?.memberIDs == [fixture.a1, fixture.a2])
    }
}

struct DocumentDirtyStateTests {
    /// Gap from WP2b: a save snapshot between adding a topic and naming it
    /// left the rename without its own undo registration (document not dirty).
    @Test func renameAfterSnapshotRegistersItsOwnStep() throws {
        let undo = UndoTests.makeUndoManager()
        let document = MindMapDocument()
        let model = document.model
        let id = try #require(model.addChild(to: model.root.id, text: "Main Topic", undoManager: undo))
        _ = try document.snapshot(contentType: .mindMap) // autosave
        let levelBefore = undo.groupingLevel
        #expect(model.rename(id, to: "Named", coalescing: true, undoManager: undo))
        #expect(undo.groupingLevel == levelBefore)
        #expect(undo.undoActionName == "Rename Topic") // own step => document becomes dirty
        undo.undo()
        #expect(model.map.node(withID: id)?.text == "Main Topic") // only the rename was undone
        undo.undo()
        #expect(model.map.node(withID: id) == nil)
    }

    @Test func renameWithoutSnapshotStillCoalesces() throws {
        let undo = UndoTests.makeUndoManager()
        let model = MindMapModel()
        let id = try #require(model.addChild(to: model.root.id, text: "Main Topic", undoManager: undo))
        #expect(model.rename(id, to: "Named", coalescing: true, undoManager: undo))
        undo.undo()
        #expect(model.map.node(withID: id) == nil)
        #expect(!undo.canUndo)
    }
}

struct PackageTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mindmap")
    }

    @Test func savingKeepsAttachmentsAndUnknownEntries() throws {
        let attachment = Attachment()
        let map = MindMap(root: Node(text: "r", attachments: [attachment]))
        let first = try MindMapPackage.fileWrapper(for: map)
        let payload = Data("# note\n".utf8)
        let note = FileWrapper(regularFileWithContents: payload)
        note.preferredFilename = "\(attachment.id.uuidString).md"
        first.fileWrappers?["attachments"]?.addFileWrapper(note)
        let extra = FileWrapper(regularFileWithContents: Data("future".utf8))
        extra.preferredFilename = "extra.json"
        first.addFileWrapper(extra)

        let url = tempURL(), url2 = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url2)
        }
        try first.write(to: url, options: .atomic, originalContentsURL: nil)
        let existing = try FileWrapper(url: url)

        var edited = try MindMapPackage.read(existing)
        edited.root.text = "edited"
        let second = try MindMapPackage.fileWrapper(for: edited, existing: existing)
        try second.write(to: url2, options: .atomic, originalContentsURL: url)

        let reread = try FileWrapper(url: url2)
        #expect(try MindMapPackage.read(reread) == edited)
        let files = reread.fileWrappers?["attachments"]?.fileWrappers
        #expect(files?["\(attachment.id.uuidString).md"]?.regularFileContents == payload)
        #expect(reread.fileWrappers?["extra.json"]?.regularFileContents == Data("future".utf8))
        #expect(Set(reread.fileWrappers?.keys.map { $0 } ?? []) == ["map.json", "attachments", "extra.json"])
    }

    @Test func attachmentsFileInsteadOfFolderIsReplaced() throws {
        let bogus = FileWrapper(regularFileWithContents: Data())
        bogus.preferredFilename = "attachments"
        let existing = FileWrapper(directoryWithFileWrappers: ["attachments": bogus])
        let wrapper = try MindMapPackage.fileWrapper(for: MindMap(), existing: existing)
        #expect(wrapper.fileWrappers?["attachments"]?.isDirectory == true)
    }

    @Test func readRejectsInvalidPackages() {
        #expect(throws: (any Error).self) { try MindMapPackage.read(FileWrapper(regularFileWithContents: Data())) }
        #expect(throws: (any Error).self) { try MindMapPackage.read(FileWrapper(directoryWithFileWrappers: [:])) }
        let broken = FileWrapper(regularFileWithContents: Data("{".utf8))
        #expect(throws: (any Error).self) {
            try MindMapPackage.read(FileWrapper(directoryWithFileWrappers: ["map.json": broken]))
        }
    }

    @Test func jsonHasNoAbsolutePaths() throws {
        let map = MindMap(root: Node(text: "r", attachments: [Attachment()]))
        let text = String(decoding: try MindMapPackage.encode(map), as: UTF8.self)
        #expect(!text.contains("file://"))
        #expect(!text.contains("/Users/"))
    }

    @Test func decodesOldMapWithOnlyRoot() throws {
        let id = UUID()
        let map = try MindMapPackage.decode(Data(#"{"root":{"id":"\#(id.uuidString)"}}"#.utf8))
        #expect(map.root.id == id)
        #expect(map.root.text.isEmpty && map.root.children.isEmpty && map.root.attachments.isEmpty)
        #expect(map.formatVersion == MindMap.currentFormatVersion)
        #expect(map.theme == .rainbow)
        // And it saves + reopens as a normal package.
        let reread = try MindMapPackage.read(MindMapPackage.fileWrapper(for: map))
        #expect(reread == map)
    }
}

struct EdgeCaseTests {
    @Test func emptyAndVeryLongTextStayCompact() {
        let measurer = NodeMeasurer()
        let empty = measurer.textSize("", fontSize: 14, weight: .regular)
        #expect(empty.width >= NodeMeasurer.minTextWidth && empty.height > 0)
        let line = measurer.textSize("Short", fontSize: 14, weight: .regular)
        let long = measurer.textSize(String(repeating: "very long topic text ", count: 200), fontSize: 14,
                                     weight: .regular)
        #expect(long.width <= NodeMeasurer.maxTextWidth + 2)
        #expect(long.height <= line.height * CGFloat(NodeMeasurer.maxLines) + 1)
        #expect(long.height > line.height * CGFloat(NodeMeasurer.maxLines - 1))
        let word = measurer.textSize(String(repeating: "x", count: 500), fontSize: 14, weight: .regular)
        #expect(word.width <= NodeMeasurer.maxTextWidth + 2)
    }

    @Test func zoomIsClamped() {
        var viewport = Viewport()
        viewport.zoom(to: 100, around: .zero)
        #expect(viewport.scale == Viewport.maxScale)
        viewport.zoom(to: 0.0001, around: .zero)
        #expect(viewport.scale == Viewport.minScale)
        let huge = Viewport.fitting(CGRect(x: 0, y: 0, width: 1_000_000, height: 10), in: CGSize(width: 800, height: 600))
        #expect(huge.scale == Viewport.minScale)
        let tiny = Viewport.fitting(CGRect(x: 0, y: 0, width: 1, height: 1), in: CGSize(width: 800, height: 600))
        #expect(tiny.scale == 1.5)
    }

    @Test func collapsingAnAncestorMovesSelectionUp() throws {
        let undo = UndoTests.makeUndoManager()
        let leaf = Node(text: "leaf")
        let branch = Node(text: "branch", children: [leaf])
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", children: [branch]))))
        editor.undoManager = undo
        editor.beginEditing(leaf.id)
        editor.draftText = "edited"
        editor.toggleCollapse(branch.id)
        editor.validateSelection() // ContentView does this on every map change
        #expect(editor.model.map.node(withID: leaf.id)?.text == "edited") // edit committed first
        #expect(editor.editingID == nil)
        #expect(editor.selectedID == branch.id)
    }

    /// An existing topic committed empty is kept (and still laid out); a
    /// just-added one is deleted (EditingKeysTests).
    @Test func emptyTextCommitIsKept() throws {
        let undo = UndoTests.makeUndoManager()
        let editor = EditorController(model: MindMapModel())
        editor.undoManager = undo
        editor.select(editor.model.root.id)
        editor.perform(.addChild)
        let id = try #require(editor.editingID)
        editor.draftText = ""
        editor.commitEditing()
        #expect(editor.model.map.node(withID: id) == nil)

        editor.perform(.addChild)
        let kept = try #require(editor.editingID)
        editor.commitEditing()
        editor.beginEditing(kept)
        editor.draftText = ""
        editor.commitEditing()
        #expect(editor.model.map.node(withID: kept)?.text == "")
        #expect(editor.scene.layout.frames[kept].map { $0.width > 0 && $0.height > 0 } == true)
    }

    @Test func inlineLabelEditing() throws {
        let undo = UndoTests.makeUndoManager()
        let a = Node(text: "a"), b = Node(text: "b")
        let relationship = Relationship(from: a.id, to: b.id)
        let map = MindMap(root: Node(text: "r", children: [a, b]), relationships: [relationship])
        let editor = EditorController(model: MindMapModel(map: map))
        editor.undoManager = undo
        let item = CanvasItem.relationship(relationship.id)
        editor.beginLabelEdit(item)
        #expect(editor.labelEditing == item)
        #expect(editor.commandState.isEditing)
        #expect(!editor.perform(.delete)) // keys go to the field
        editor.labelDraft = " depends "
        editor.select(a.id) // clicking elsewhere commits
        #expect(editor.labelEditing == nil)
        #expect(editor.relationship(relationship.id)?.label == "depends")
        undo.undo()
        #expect(editor.relationship(relationship.id)?.label == nil)

        editor.beginLabelEdit(item)
        editor.cancelLabelEdit()
        #expect(editor.labelEditing == nil && !undo.canUndo)
    }
}

struct PerformanceTests {
    private static func bigMap(nodes: Int) -> MindMap {
        // ~10 main branches, 10 children each, 10 grandchildren each.
        var counter = 0
        func make(_ level: Int) -> Node {
            counter += 1
            let text = "Topic \(counter) " + String(repeating: "word ", count: counter % 6)
            guard level < 3 else { return Node(text: text) }
            return Node(text: text, children: (0..<10).compactMap { _ in counter < nodes ? make(level + 1) : nil })
        }
        return MindMap(root: make(0))
    }

    @Test func layoutOfThousandNodesIsFast() {
        let map = Self.bigMap(nodes: 1_000)
        #expect(map.root.subtreeCount >= 1_000)
        let clock = ContinuousClock()
        var result: TreeLayout.Result?
        let elapsed = clock.measure {
            result = TreeLayout().layout(map) { _ in CGSize(width: 120, height: 36) }
        }
        #expect(result?.frames.count == map.root.subtreeCount)
        #expect(TestTree.overlappingPairs(result?.frames ?? [:]) == 0)
        print("PERF layout 1000 nodes: \(elapsed)")
        #expect(elapsed < .milliseconds(500), "layout took \(elapsed)")
    }

    /// One keystroke while editing rebuilds the scene; measurements of all
    /// other topics come from the cache, so this stays well below a frame
    /// budget even for large maps (generous bound for CI/simulator).
    @Test func sceneRebuildPerKeystrokeUsesMeasureCache() throws {
        let map = Self.bigMap(nodes: 1_000)
        let measurer = NodeMeasurer()
        let clock = ContinuousClock()
        let first = clock.measure { _ = MapScene.build(map: map, measurer: measurer, editing: nil) }
        let id = try #require(map.root.children.first?.id)
        var keystroke = Duration.zero
        for i in 0..<5 {
            keystroke += clock.measure {
                _ = MapScene.build(map: map, measurer: measurer, editing: (id, "typing \(i)"))
            }
        }
        print("PERF scene first build: \(first), per keystroke: \(keystroke / 5)")
        #expect(keystroke / 5 < .milliseconds(150), "rebuild took \(keystroke / 5) (first \(first))")
    }
}
