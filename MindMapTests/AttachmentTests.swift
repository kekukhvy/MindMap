import CoreGraphics
import Foundation
import Testing
@testable import MindMap

private func makeUndo() -> UndoManager {
    let undo = UndoManager()
    undo.groupsByEvent = false
    return undo
}

private func text(_ model: MindMapModel, _ id: UUID) -> String {
    MarkdownNote.text(model.content(of: id))
}

/// Model ops + undo for attachments (WP4).
struct AttachmentModelTests {
    private func makeModel() -> (MindMapModel, topic: UUID) {
        let topic = Node(text: "Ideas")
        return (MindMapModel(map: MindMap(root: Node(text: "Central", children: [topic]))), topic.id)
    }

    @Test func addNoteCreatesMarkdownFileWithHeading() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addNote(to: topic, undoManager: undo))
        let attachment = try #require(model.attachment(id))
        #expect(attachment.kind == .markdown)
        #expect(attachment.fileName == "\(id.uuidString).md")
        #expect(attachment.title == "Note")
        #expect(text(model, id) == "# Ideas\n\n")
        #expect(undo.undoActionName == "Add Note")

        undo.undo()
        #expect(model.map.node(withID: topic)?.attachments.isEmpty == true)
        undo.redo()
        #expect(model.attachment(id) == attachment)
        #expect(text(model, id) == "# Ideas\n\n")
        // A second note gets its own title and file.
        let second = try #require(model.addNote(to: topic, undoManager: undo))
        #expect(model.attachment(second)?.title == "Note 2")
        #expect(model.map.node(withID: topic)?.attachments.map(\.id) == [id, second])
    }

    @Test func removeAndUndoRestoresReferenceAndContent() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addNote(to: topic, undoManager: undo))
        #expect(model.setAttachmentContent(MarkdownNote.data("# Ideas\n\nbody"), for: id, undoManager: undo))
        #expect(model.removeAttachment(id, undoManager: undo))
        #expect(model.attachment(id) == nil)
        #expect(undo.undoActionName == "Remove Note")
        undo.undo()
        #expect(model.attachment(id) != nil)
        #expect(text(model, id) == "# Ideas\n\nbody")
    }

    @Test func renameAndReorderAreSingleUndoSteps() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let a = try #require(model.addNote(to: topic, undoManager: undo))
        let file = Attachment(kind: .file, title: "Spec", originalExtension: "pdf")
        #expect(file.fileName == "\(file.id.uuidString).pdf")
        #expect(model.addAttachment(file, to: topic, content: Data([1, 2, 3]), undoManager: undo))

        #expect(model.renameAttachment(a, to: "Summary", undoManager: undo))
        #expect(model.attachment(a)?.title == "Summary")
        #expect(!model.renameAttachment(a, to: "Summary", undoManager: undo))
        undo.undo()
        #expect(model.attachment(a)?.title == "Note")

        #expect(model.moveAttachment(file.id, to: 0, undoManager: undo))
        #expect(model.map.node(withID: topic)?.attachments.map(\.id) == [file.id, a])
        #expect(!model.moveAttachment(file.id, to: 0, undoManager: undo))
        undo.undo()
        #expect(model.map.node(withID: topic)?.attachments.map(\.id) == [a, file.id])
    }

    @Test func invalidOperationsChangeNothing() {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        #expect(model.addNote(to: UUID(), undoManager: undo) == nil)
        #expect(!model.removeAttachment(UUID(), undoManager: undo))
        #expect(!model.renameAttachment(UUID(), to: "x", undoManager: undo))
        #expect(!model.setAttachmentContent(Data("x".utf8), for: UUID(), undoManager: undo))
        let bad = Attachment(kind: .file, fileName: "../escape")
        #expect(!model.addAttachment(bad, to: topic, undoManager: undo))
        #expect(!undo.canUndo)
        // Duplicate ids / file names are rejected.
        let ok = Attachment(kind: .markdown)
        #expect(model.addAttachment(ok, to: topic, undoManager: undo))
        #expect(!model.addAttachment(ok, to: model.root.id, undoManager: undo))
        #expect(!model.addAttachment(Attachment(kind: .file, fileName: ok.fileName), to: topic, undoManager: undo))
    }

    @Test func deletingTopicKeepsAttachmentsForUndo() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let child = try #require(model.addChild(to: topic, text: "Child", undoManager: undo))
        let note = try #require(model.addNote(to: child, undoManager: undo))
        #expect(model.setAttachmentContent(MarkdownNote.data("kept"), for: note, undoManager: undo))
        #expect(model.delete(topic, undoManager: undo))
        #expect(model.attachment(note) == nil)
        undo.undo()
        #expect(model.map.attachment(withID: note)?.nodeID == child)
        #expect(text(model, note) == "kept")
    }

    @Test func contentEditsCoalesceWhileTyping() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addNote(to: topic, undoManager: undo))
        let start = Date()
        let created = try #require(model.attachment(id)).modifiedAt
        #expect(model.setAttachmentContent(MarkdownNote.data("a"), for: id, undoManager: undo, now: start))
        #expect(model.setAttachmentContent(MarkdownNote.data("ab"), for: id, undoManager: undo,
                                           now: start.addingTimeInterval(0.5)))
        #expect(model.setAttachmentContent(MarkdownNote.data("abc"), for: id, undoManager: undo,
                                           now: start.addingTimeInterval(1)))
        #expect(model.attachment(id)?.modifiedAt == start)
        // Pause: new step.
        #expect(model.setAttachmentContent(MarkdownNote.data("abcd"), for: id, undoManager: undo,
                                           now: start.addingTimeInterval(5)))
        #expect(undo.undoActionName == "Edit Note")
        // Unchanged content registers nothing.
        #expect(!model.setAttachmentContent(MarkdownNote.data("abcd"), for: id, undoManager: undo))

        undo.undo()
        #expect(text(model, id) == "abc")
        undo.undo()
        #expect(text(model, id) == "# Ideas\n\n")
        #expect(model.attachment(id)?.modifiedAt == created)
        undo.redo()
        #expect(text(model, id) == "abc")
        undo.redo()
        #expect(text(model, id) == "abcd")
        undo.undo()
        undo.undo()
        undo.undo() // Add Note
        #expect(model.attachment(id) == nil)
    }

    @Test func otherStepsAndSavesBreakContentCoalescing() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addNote(to: topic, undoManager: undo))
        let now = Date()
        model.setAttachmentContent(MarkdownNote.data("one"), for: id, undoManager: undo, now: now)
        model.breakCoalescing() // autosave snapshot
        model.setAttachmentContent(MarkdownNote.data("two"), for: id, undoManager: undo, now: now)
        model.rename(topic, to: "Renamed", undoManager: undo)
        model.setAttachmentContent(MarkdownNote.data("three"), for: id, undoManager: undo, now: now)
        undo.undo()
        #expect(text(model, id) == "two")
        undo.undo()
        #expect(model.map.node(withID: topic)?.text == "Ideas")
        undo.undo()
        #expect(text(model, id) == "one")
    }
}

/// `AttachmentStore` + package through real files on disk.
struct AttachmentStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Store-\(UUID().uuidString)")
            .appendingPathExtension("mindmap")
    }

    /// Saves like the document classes do (snapshot on main, then write).
    private func save(_ document: MindMapDocument, to url: URL, previous: URL?) throws {
        let snapshot = try document.snapshot(contentType: .mindMap)
        let existing = try previous.map { try FileWrapper(url: $0) }
        let wrapper = try MindMapDocument.package(for: snapshot, existing: existing)
        try wrapper.write(to: url, options: .atomic, originalContentsURL: previous)
    }

    private func open(_ url: URL) throws -> MindMapModel {
        let wrapper = try FileWrapper(url: url)
        let map = try MindMapPackage.read(wrapper)
        return MindMapModel(map: map, attachmentStore: AttachmentStore(package: wrapper,
                                                                       referenced: map.referencedAttachmentFileNames))
    }

    private func attachmentFiles(_ url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("attachments").path)) ?? [])
    }

    @Test func noteRoundTripsAsPlainMarkdownFile() throws {
        let document = MindMapDocument()
        let model = document.model
        let undo = makeUndo()
        let topic = try #require(model.addChild(to: model.root.id, text: "Plan", undoManager: undo))
        let note = try #require(model.addNote(to: topic, undoManager: undo))
        let body = "# Plan\n\nÜmlauts, emoji 🧠 and **bold**.\n- one\n"
        model.setAttachmentContent(MarkdownNote.data(body), for: note, undoManager: undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(document, to: url, previous: nil)

        // Plain UTF-8 .md file in attachments/, readable by any editor (Obsidian).
        let file = url.appendingPathComponent("attachments/\(note.uuidString).md")
        #expect(try String(contentsOf: file, encoding: .utf8) == body)
        #expect(attachmentFiles(url) == ["\(note.uuidString).md"])

        let reopened = try open(url)
        #expect(reopened.map == model.map)
        #expect(MarkdownNote.text(reopened.content(of: note)) == body)
        #expect(!reopened.attachmentStore.hasPendingChanges)
    }

    @Test func unchangedFilesAreReusedNotRewritten() throws {
        let note = Attachment(kind: .markdown, title: "N")
        let map = MindMap(root: Node(text: "r", attachments: [note]))
        let first = try MindMapPackage.fileWrapper(for: map, attachments: [
            note.fileName: { let w = FileWrapper(regularFileWithContents: Data("x".utf8)); w.preferredFilename = note.fileName; return w }()
        ])
        let store = AttachmentStore(package: first, referenced: map.referencedAttachmentFileNames)
        let loaded = try #require(first.fileWrappers?["attachments"]?.fileWrappers?[note.fileName])
        let children = store.prepareSave(referencing: map.referencedAttachmentFileNames)
        #expect(children[note.fileName] === loaded)
        // A written file gets a new wrapper; the next save reuses that one.
        store.write(Data("y".utf8), to: note.fileName)
        let written = try #require(store.prepareSave(referencing: [note.fileName])[note.fileName])
        #expect(written !== loaded)
        #expect(store.prepareSave(referencing: [note.fileName])[note.fileName] === written)
        #expect(store.data(for: note.fileName) == Data("y".utf8))
    }

    @Test func orphansAreRemovedOnSaveAndUndoBringsThemBack() throws {
        let document = MindMapDocument()
        let model = document.model
        let undo = makeUndo()
        let note = try #require(model.addNote(to: model.root.id, undoManager: undo))
        model.setAttachmentContent(MarkdownNote.data("precious"), for: note, undoManager: undo)
        let urls = [tempURL(), tempURL(), tempURL()]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        try save(document, to: urls[0], previous: nil)
        let name = "\(note.uuidString).md"
        #expect(attachmentFiles(urls[0]) == [name])

        #expect(model.removeAttachment(note, undoManager: undo))
        try save(document, to: urls[1], previous: urls[0])
        #expect(attachmentFiles(urls[1]).isEmpty)

        undo.undo()
        try save(document, to: urls[2], previous: urls[1])
        #expect(attachmentFiles(urls[2]) == [name])
        let file = urls[2].appendingPathComponent("attachments/\(name)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "precious")
    }

    @Test func undoneAddIsNotSavedAndUnknownOrphansAreDropped() throws {
        // A package with a stray file nothing refers to.
        let stray = FileWrapper(regularFileWithContents: Data("stray".utf8))
        stray.preferredFilename = "stray.bin"
        let package = try MindMapPackage.fileWrapper(for: MindMap(), attachments: ["stray.bin": stray])
        let map = try MindMapPackage.read(package)
        let store = AttachmentStore(package: package, referenced: map.referencedAttachmentFileNames)
        let model = MindMapModel(map: map, attachmentStore: store)
        let undo = makeUndo()
        let note = try #require(model.addNote(to: model.root.id, undoManager: undo))
        undo.undo()
        let children = store.prepareSave(referencing: model.map.referencedAttachmentFileNames)
        #expect(children.isEmpty)
        #expect(!store.contains("stray.bin"))
        // The undone note's bytes stay available for redo.
        undo.redo()
        #expect(model.content(of: note) != nil)
        #expect(store.prepareSave(referencing: model.map.referencedAttachmentFileNames).keys.sorted()
                == ["\(note.uuidString).md"])
    }

    @Test func storeIgnoresUnsafeNamesAndResetBumpsRevisions() {
        let store = AttachmentStore()
        #expect(!store.write(Data(), to: "a/b.md"))
        #expect(!store.write(Data(), to: ".hidden"))
        #expect(store.write(Data("1".utf8), to: "ok.md"))
        let revision = store.revision(of: "ok.md")
        store.reset(package: nil)
        #expect(store.revision(of: "ok.md") > revision)
        #expect(store.data(for: "ok.md") == nil)
    }
}

/// JSON compatibility of attachments with Stage 1 files.
struct AttachmentJSONTests {
    @Test func stageOnePlaceholderDecodes() throws {
        let node = UUID(), attachment = UUID()
        let json = #"{"formatVersion":1,"root":{"id":"\#(node.uuidString)","text":"Old","attachments":[{"id":"\#(attachment.uuidString)"}]}}"#
        let map = try MindMapPackage.decode(Data(json.utf8))
        let decoded = try #require(map.root.attachments.first)
        #expect(decoded.id == attachment)
        #expect(decoded.kind == .file)
        #expect(decoded.title.isEmpty)
        #expect(decoded.fileName == attachment.uuidString)
        #expect(decoded.modifiedAt == decoded.createdAt)
        // Saves and reopens unchanged.
        #expect(try MindMapPackage.decode(MindMapPackage.encode(map)) == map)
    }

    @Test func fullAttachmentRoundTripsAndUnknownKindFallsBack() throws {
        let attachment = Attachment(kind: .drawing, title: "Sketch", createdAt: Date(timeIntervalSince1970: 1_700_000_000.25),
                                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_100.5))
        #expect(attachment.fileName.hasSuffix(".drawing"))
        let map = MindMap(root: Node(text: "r", attachments: [attachment]))
        let data = try MindMapPackage.encode(map)
        #expect(try MindMapPackage.decode(data) == map)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"kind\" : \"drawing\""))
        #expect(text.contains(attachment.fileName))

        let json = #"{"id":"\#(UUID().uuidString)","kind":"hologram","title":"T","fileName":"x.holo"}"#
        let future = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(future.kind == .file)
        #expect(future.fileName == "x.holo")
    }
}

/// Topic sizes reserve the icon row; icon row rules.
struct AttachmentLayoutTests {
    @Test func nodeSizeIncludesIcons() throws {
        let plain = Node(text: "Same text")
        var withNote = Node(text: "Same text")
        withNote.attachments = [Attachment(kind: .markdown)]
        var withMany = Node(text: "Same text")
        withMany.attachments = [Attachment(kind: .markdown), Attachment(kind: .file), Attachment(kind: .drawing),
                                Attachment(kind: .file), Attachment(kind: .file)]
        let map = MindMap(root: Node(text: "Root", layoutStyle: .rightMap, children: [plain, withNote, withMany]))
        let scene = MapScene.build(map: map, measurer: NodeMeasurer(), editing: nil)
        let a = try #require(scene.layout.frames[plain.id])
        let b = try #require(scene.layout.frames[withNote.id])
        let c = try #require(scene.layout.frames[withMany.id])
        let font = try #require(scene.nodes[withNote.id]).appearance.fontSize
        let one = AttachmentIconRow.width(AttachmentIconRow.items([AttachmentSummary(withNote.attachments[0])]),
                                          fontSize: font)
        #expect(one > 0)
        #expect(approx(b.width - a.width, one))
        #expect(c.width > b.width)
        #expect(scene.nodes[withMany.id]?.attachments.count == 5)
        #expect(TestTree.overlappingPairs(scene.layout.frames) == 0)
    }

    @Test func iconRowCollapsesAboveThree() {
        let three = [Attachment(kind: .markdown), Attachment(kind: .markdown), Attachment(kind: .file)]
            .map(AttachmentSummary.init)
        #expect(AttachmentIconRow.items(three).count == 3)
        let five = (three + [Attachment(kind: .drawing), Attachment(kind: .file)].map(AttachmentSummary.init))
        let items = AttachmentIconRow.items(five)
        #expect(items == [.icon(.markdown, attachmentID: five[0].id), .icon(.file, attachmentID: five[2].id),
                          .icon(.drawing, attachmentID: five[3].id), .count(5)])
        #expect(AttachmentIconRow.width([], fontSize: 16) == 0)
    }
}

struct AttachmentEditorTests {
    @Test func noteCommandAddsThenOpens() throws {
        let topic = Node(text: "T")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "R", children: [topic]))))
        let undo = makeUndo()
        editor.undoManager = undo
        editor.select(topic.id)
        #expect(KeyCommandMap.command(key: KeyEquivalentShim.n, modifiers: [.command, .shift], characters: "N") == .note)
        #expect(editor.perform(.note))
        let note = try #require(editor.firstNote(of: topic.id))
        #expect(editor.presentedAttachment?.attachmentID == note.id)
        #expect(editor.commandState.selectionHasNote)
        editor.presentedAttachment = nil
        #expect(editor.perform(.note))
        #expect(editor.presentedAttachment?.attachmentID == note.id)
        #expect(editor.attachments(of: topic.id).count == 1)
        editor.addNote(to: topic.id)
        #expect(editor.attachments(of: topic.id).count == 2)
        editor.removeAttachment(note.id)
        #expect(editor.attachments(of: topic.id).count == 1)
    }

    @Test func markdownPreviewBlocks() {
        let blocks = MarkdownBlock.parse("# Title\n\nText *em*\n- a\n  - b\n1. one\n- [x] done\n> quote\n---\n```\ncode\n```")
        #expect(blocks == [.heading(level: 1, text: "Title"), .blank, .paragraph("Text *em*"),
                           .bullet(text: "a", indent: 0), .bullet(text: "b", indent: 1),
                           .numbered(marker: "1.", text: "one", indent: 0), .task(done: true, text: "done", indent: 0),
                           .quote("quote"), .rule, .code("code")])
        #expect(MarkdownNote.initialContent(topicText: "Multi\nline") == "# Multi line\n\n")
        #expect(MarkdownNote.initialContent(topicText: "  ") == "")
    }

    @MainActor @Test func registryFindsLiveDocumentsOnly() {
        let registry = OpenDocumentRegistry()
        var model: MindMapModel? = MindMapModel()
        let id = model!.documentID
        let undo = UndoManager()
        registry.register(model!, undoManager: undo)
        #expect(registry.entry(for: id)?.model === model)
        #expect(registry.entry(for: id)?.undoManager === undo)
        model = nil
        #expect(registry.entry(for: id) == nil)
        let other = MindMapModel()
        registry.register(other, undoManager: nil)
        registry.unregister(other)
        #expect(registry.entry(for: other.documentID) == nil)
    }
}

import SwiftUI

private enum KeyEquivalentShim {
    static let n = KeyEquivalent("n")
}

#if os(iOS)
import UIKit

@MainActor
struct AttachmentUIDocumentTests {
    @Test func noteEditsMarkDirtyAndRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UIDocNote-\(UUID().uuidString).mindmap")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MindMapUIDocument(fileURL: url)
        #expect(await document.save(to: url, for: .forCreating))
        let undo = makeUndo()
        document.undoManager = undo
        let note = try #require(document.model.addNote(to: document.model.root.id, undoManager: undo))
        #expect(await document.save(to: url, for: .forOverwriting))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!document.hasUnsavedChanges)
        document.model.setAttachmentContent(MarkdownNote.data("# Central Topic\n\nfrom iPad"), for: note,
                                            undoManager: undo)
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.hasUnsavedChanges)
        #expect(await document.close())

        let file = url.appendingPathComponent("attachments/\(note.uuidString).md")
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Central Topic\n\nfrom iPad")
        let reopened = MindMapUIDocument(fileURL: url)
        #expect(await reopened.open())
        #expect(MarkdownNote.text(reopened.model.content(of: note)) == "# Central Topic\n\nfrom iPad")
        #expect(await reopened.close())
    }
}
#endif
