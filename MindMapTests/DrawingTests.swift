import Foundation
import PencilKit
import SwiftUI
import Testing
@testable import MindMap

private func makeUndo() -> UndoManager {
    let undo = UndoManager()
    undo.groupsByEvent = false
    return undo
}

private func drawing(_ model: MindMapModel, _ id: UUID) -> PKDrawing {
    HandwrittenNote.drawing(model.content(of: id))
}

/// One synthetic pen stroke (deterministic points).
private func line(from a: CGPoint, to b: CGPoint, color: DebugInkColor = .black) -> PKStroke {
    DebugDrawing.stroke((0...20).map { i in
        let t = CGFloat(i) / 20
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }, color: color, width: 4)
}

/// Stroke geometry that survives `dataRepresentation()` (control points).
private func signature(_ drawing: PKDrawing) -> [[CGPoint]] {
    drawing.strokes.map { stroke in stroke.path.map(\.location) }
}

/// Handwritten notes (WP5): model ops + undo.
struct DrawingModelTests {
    private func makeModel() -> (MindMapModel, topic: UUID) {
        let topic = Node(text: "Sketches")
        return (MindMapModel(map: MindMap(root: Node(text: "Central", children: [topic]))), topic.id)
    }

    @Test func addDrawingCreatesEmptyPencilKitFile() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: topic, undoManager: undo))
        let attachment = try #require(model.attachment(id))
        #expect(attachment.kind == .drawing)
        #expect(attachment.fileName == "\(id.uuidString).drawing")
        #expect(attachment.title == "Handwritten Note")
        #expect(undo.undoActionName == "Add Handwritten Note")
        let data = try #require(model.content(of: id))
        #expect(try PKDrawing(data: data).strokes.isEmpty)

        undo.undo()
        #expect(model.attachment(id) == nil)
        undo.redo()
        #expect(model.attachment(id) == attachment)
        #expect(model.content(of: id) == data)
        let second = try #require(model.addDrawing(to: topic, undoManager: undo))
        #expect(model.attachment(second)?.title == "Handwritten Note 2")
        #expect(model.addDrawing(to: UUID(), undoManager: undo) == nil)
    }

    @Test func eachDrawBatchIsOneUndoStep() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: topic, undoManager: undo))
        var sketch = PKDrawing()
        sketch.strokes.append(line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 40)))
        let one = sketch
        let start = Date()
        #expect(model.setAttachmentContent(one.dataRepresentation(), for: id, actionName: "Draw", coalescing: false,
                                           undoManager: undo, now: start))
        sketch.strokes.append(line(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 300, y: 90), color: .red))
        // Within the note-typing coalesce interval, but drawings never coalesce.
        #expect(model.setAttachmentContent(sketch.dataRepresentation(), for: id, actionName: "Draw", coalescing: false,
                                           undoManager: undo, now: start.addingTimeInterval(0.5)))
        #expect(undo.undoActionName == "Draw")
        #expect(drawing(model, id).strokes.count == 2)
        #expect(model.attachment(id)?.modifiedAt == start.addingTimeInterval(0.5))

        undo.undo()
        #expect(signature(drawing(model, id)) == signature(one))
        undo.undo()
        #expect(drawing(model, id).strokes.isEmpty)
        #expect(undo.undoActionName == "Add Handwritten Note")
        undo.redo()
        undo.redo()
        #expect(drawing(model, id).strokes.count == 2)
        // Same bytes again: no step.
        #expect(!model.setAttachmentContent(sketch.dataRepresentation(), for: id, actionName: "Draw",
                                            coalescing: false, undoManager: undo))
    }

    @Test func removeAndTopicDeleteUndoRestoreTheDrawing() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: topic, content: DebugDrawing.sample().dataRepresentation(),
                                               undoManager: undo))
        let bytes = try #require(model.content(of: id))
        #expect(model.removeAttachment(id, undoManager: undo))
        #expect(undo.undoActionName == "Remove Handwritten Note")
        #expect(model.attachment(id) == nil)
        undo.undo()
        #expect(model.content(of: id) == bytes)

        #expect(model.delete(topic, undoManager: undo))
        #expect(model.attachment(id) == nil)
        undo.undo()
        #expect(model.content(of: id) == bytes)
        #expect(signature(drawing(model, id)) == signature(DebugDrawing.sample()))
    }

    @Test func corruptOrMissingDataIsAnEmptyDrawing() {
        #expect(HandwrittenNote.drawing(nil).strokes.isEmpty)
        #expect(HandwrittenNote.drawing(Data()).strokes.isEmpty)
        #expect(HandwrittenNote.drawing(Data("not a drawing".utf8)).strokes.isEmpty)
        let sample = DebugDrawing.sample()
        #expect(HandwrittenNote.pageHeight(for: PKDrawing(), minHeight: 500) == 500)
        #expect(HandwrittenNote.pageHeight(for: sample, minHeight: 100)
                == sample.bounds.maxY + HandwrittenNote.bottomMargin)
    }

    @Test func handwritingCommandAddsThenOpensFullScreen() throws {
        let topic = Node(text: "T")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "R", children: [topic]))))
        editor.undoManager = makeUndo()
        editor.select(topic.id)
        #expect(KeyCommandMap.command(key: KeyEquivalent("d"), modifiers: [.command, .shift], characters: "D")
                == .handwrittenNote)
        #expect(KeyCommandMap.command(key: KeyEquivalent("d"), modifiers: [.command], characters: "d") == nil)
        #expect(!editor.commandState.selectionHasDrawing)
        #expect(editor.perform(.handwrittenNote))
        let sketch = try #require(editor.firstDrawing(of: topic.id))
        #expect(editor.presentedAttachment?.attachmentID == sketch.id)
        #expect(editor.presentedAttachment?.fullScreen == true)
        #expect(editor.commandState.selectionHasDrawing)
        editor.presentedAttachment = nil
        #expect(editor.perform(.handwrittenNote))
        #expect(editor.presentedAttachment?.attachmentID == sketch.id)
        #expect(editor.attachments(of: topic.id).count == 1)
        editor.addDrawing(to: topic.id)
        #expect(editor.attachments(of: topic.id).count == 2)
        // Markdown notes still open as a page sheet.
        editor.addNote(to: topic.id)
        #expect(editor.presentedAttachment?.fullScreen == false)
    }
}

/// Drawings through a real package on disk + JSON compatibility.
struct DrawingStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Drawing-\(UUID().uuidString)")
            .appendingPathExtension("mindmap")
    }

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

    @Test func drawingRoundTripsThroughPackageOnDisk() throws {
        let document = MindMapDocument()
        let model = document.model
        let undo = makeUndo()
        let topic = try #require(model.addChild(to: model.root.id, text: "Sketch", undoManager: undo))
        let id = try #require(model.addDrawing(to: topic, undoManager: undo))
        var original = PKDrawing()
        original.strokes.append(line(from: CGPoint(x: 12, y: 30), to: CGPoint(x: 400, y: 260)))
        original.strokes.append(line(from: CGPoint(x: 50, y: 300), to: CGPoint(x: 90, y: 900), color: .blue))
        model.setAttachmentContent(original.dataRepresentation(), for: id, actionName: "Draw", coalescing: false,
                                   undoManager: undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(document, to: url, previous: nil)

        let name = "\(id.uuidString).drawing"
        #expect(attachmentFiles(url) == [name])
        // The file is exactly PKDrawing.dataRepresentation().
        let file = try Data(contentsOf: url.appendingPathComponent("attachments/\(name)"))
        let fromFile = try PKDrawing(data: file)
        #expect(try fromFile == PKDrawing(data: original.dataRepresentation()))
        #expect(signature(fromFile) == signature(original))
        #expect(fromFile.strokes.map(\.ink.inkType) == [.pen, .pen])

        let reopened = try open(url)
        #expect(reopened.map == model.map)
        #expect(reopened.attachment(id)?.kind == .drawing)
        let reloaded = HandwrittenNote.drawing(reopened.content(of: id))
        #expect(signature(reloaded) == signature(original))
        #expect(reloaded.bounds.integral == original.bounds.integral)
        #expect(!reopened.attachmentStore.hasPendingChanges)
    }

    @Test func orphanDrawingIsDroppedOnSaveAndUndoBringsItBack() throws {
        let document = MindMapDocument()
        let model = document.model
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: model.root.id, content: DebugDrawing.sample().dataRepresentation(),
                                               undoManager: undo))
        let urls = [tempURL(), tempURL(), tempURL()]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let name = "\(id.uuidString).drawing"
        try save(document, to: urls[0], previous: nil)
        #expect(attachmentFiles(urls[0]) == [name])

        #expect(model.removeAttachment(id, undoManager: undo))
        try save(document, to: urls[1], previous: urls[0])
        #expect(attachmentFiles(urls[1]).isEmpty)

        undo.undo()
        try save(document, to: urls[2], previous: urls[1])
        #expect(attachmentFiles(urls[2]) == [name])
        let data = try Data(contentsOf: urls[2].appendingPathComponent("attachments/\(name)"))
        #expect(signature(try PKDrawing(data: data)) == signature(DebugDrawing.sample()))
    }

    @Test func drawingAttachmentJSONIsCompatible() throws {
        let node = UUID(), id = UUID()
        // Written by this version: kind + fileName; read back unchanged.
        let json = #"{"formatVersion":1,"root":{"id":"\#(node.uuidString)","text":"T","attachments":[{"id":"\#(id.uuidString)","kind":"drawing","title":"Board","fileName":"\#(id.uuidString).drawing","createdAt":0,"modifiedAt":5}]}}"#
        let map = try MindMapPackage.decode(Data(json.utf8))
        let attachment = try #require(map.root.attachments.first)
        #expect(attachment.kind == .drawing)
        #expect(attachment.fileName == "\(id.uuidString).drawing")
        #expect(attachment.title == "Board")
        #expect(try MindMapPackage.decode(MindMapPackage.encode(map)) == map)
        #expect(map.referencedAttachmentFileNames == ["\(id.uuidString).drawing"])
        // Without dates (hand-written / older writer) it still decodes.
        let minimal = #"{"id":"\#(id.uuidString)","kind":"drawing"}"#
        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(minimal.utf8))
        #expect(decoded.kind == .drawing)
        #expect(decoded.fileName == id.uuidString)
    }
}

#if os(iOS)
import UIKit

/// The canvas's undo manager drops PencilKit's own registrations and
/// forwards undo/redo (after flushing pending strokes) to the document's.
@MainActor
struct DrawingUndoForwarderTests {
    @Test func registrationsAreDroppedAndUndoIsForwarded() throws {
        let document = makeUndo()
        let forwarder = DrawingUndoForwarder()
        forwarder.target = document
        var flushed = 0
        forwarder.willForward = { flushed += 1 }
        final class Box { var value = 0 }
        let box = Box()
        forwarder.registerUndo(withTarget: box) { $0.value = -1 }
        #expect(!document.canUndo)
        #expect(!forwarder.canUndo)

        func set(_ value: Int) {
            let old = box.value
            box.value = value
            document.beginUndoGrouping()
            document.registerUndo(withTarget: box) { _ in set(old) }
            document.setActionName("Draw")
            document.endUndoGrouping()
        }
        set(1)
        #expect(forwarder.canUndo)
        #expect(forwarder.undoActionName == "Draw")
        forwarder.undo()
        #expect(box.value == 0)
        #expect(flushed == 1)
        #expect(forwarder.canRedo)
        forwarder.redo()
        #expect(box.value == 1)
        #expect(flushed == 2)
        #expect(!forwarder.canRedo)

        forwarder.hasPendingChanges = { true }
        #expect(forwarder.canUndo)
        #expect(!forwarder.canRedo)
        let canvas = PencilCanvasView()
        #expect(canvas.undoManager === canvas.forwarder)
    }

    @Test func drawingEditsMarkUIDocumentDirtyAndRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UIDocDrawing-\(UUID().uuidString).mindmap")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MindMapUIDocument(fileURL: url)
        #expect(await document.save(to: url, for: .forCreating))
        let undo = makeUndo()
        document.undoManager = undo
        let id = try #require(document.model.addDrawing(to: document.model.root.id, undoManager: undo))
        #expect(await document.save(to: url, for: .forOverwriting))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!document.hasUnsavedChanges)
        let sample = DebugDrawing.sample()
        document.model.setAttachmentContent(sample.dataRepresentation(), for: id, actionName: "Draw",
                                            coalescing: false, undoManager: undo)
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.hasUnsavedChanges)
        #expect(await document.close())

        let reopened = MindMapUIDocument(fileURL: url)
        #expect(await reopened.open())
        #expect(signature(HandwrittenNote.drawing(reopened.model.content(of: id))) == signature(sample))
        #expect(await reopened.close())
    }
}
#endif
