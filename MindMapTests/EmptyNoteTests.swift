import Foundation
import PencilKit
import Testing
@testable import MindMap

/// Empty-note lifecycle (feedback batch 2): a new note / handwritten note
/// is a draft until it has content; closing its editor while empty leaves
/// no trace; a note emptied by the user is deleted on close (undoable).
@MainActor
struct EmptyNoteTests {
    private func makeUndo() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func makeModel() -> (MindMapModel, topic: UUID) {
        let topic = Node(text: "Ideas")
        return (MindMapModel(map: MindMap(root: Node(text: "Central", children: [topic]))), topic.id)
    }

    private func text(_ model: MindMapModel, _ id: UUID) -> String {
        MarkdownNote.text(model.content(of: id))
    }

    private func iconCount(_ model: MindMapModel, _ topic: UUID) -> Int {
        let editor = EditorController(model: model)
        return editor.scene.nodes[topic]?.attachments.count ?? -1
    }

    @Test func newNoteIsEmptyDraftWithoutIconOrUndoStep() throws {
        let (model, topic) = makeModel()
        let before = model.map
        let id = try #require(model.startNote(on: topic))
        let note = try #require(model.attachment(id))
        #expect(note.kind == .markdown && note.title == "Note")
        #expect(text(model, id) == "")
        #expect(model.isDraft(id))
        #expect(model.map == before)
        #expect(iconCount(model, topic) == 0)
        // Closing it empty: gone, nothing to undo, map untouched.
        let undo = makeUndo()
        #expect(model.discardIfEmpty(id, undoManager: undo))
        #expect(model.attachment(id) == nil)
        #expect(!undo.canUndo && !undo.canRedo)
        #expect(model.map == before)
    }

    @Test func blankTextKeepsDraftAndIsDiscarded() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.startNote(on: topic))
        #expect(model.setAttachmentContent(MarkdownNote.data("  \n\t\n"), for: id, undoManager: undo))
        #expect(model.isDraft(id))
        #expect(text(model, id) == "  \n\t\n")
        #expect(!undo.canUndo)
        #expect(model.discardIfEmpty(id, undoManager: undo))
        #expect(model.map.node(withID: topic)?.attachments.isEmpty == true)
        #expect(!undo.canUndo)
    }

    @Test func firstTextAddsNoteAsOneUndoStep() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.startNote(on: topic))
        let start = Date()
        #expect(model.setAttachmentContent(MarkdownNote.data("H"), for: id, undoManager: undo, now: start))
        #expect(!model.isDraft(id))
        #expect(model.map.node(withID: topic)?.attachments.map(\.id) == [id])
        #expect(undo.undoActionName == "Add Note")
        #expect(iconCount(model, topic) == 1)
        // Typing right after joins the "Add Note" step.
        #expect(model.setAttachmentContent(MarkdownNote.data("Hello"), for: id, undoManager: undo,
                                           now: start.addingTimeInterval(0.5)))
        #expect(undo.undoActionName == "Add Note")
        #expect(!model.discardIfEmpty(id, undoManager: undo))
        undo.undo()
        #expect(model.attachment(id) == nil)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(text(model, id) == "Hello")
        // A later pause starts its own "Edit Note" step.
        #expect(model.setAttachmentContent(MarkdownNote.data("Hello world"), for: id, undoManager: undo,
                                           now: Date().addingTimeInterval(10)))
        #expect(undo.undoActionName == "Edit Note")
    }

    @Test func emptiedNoteIsDeletedOnCloseUndoably() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addNote(to: topic, text: "Keep me", undoManager: undo))
        #expect(model.setAttachmentContent(MarkdownNote.data(" \n"), for: id, undoManager: undo,
                                           now: Date().addingTimeInterval(10)))
        #expect(iconCount(model, topic) == 0)
        #expect(model.discardIfEmpty(id, undoManager: undo))
        #expect(model.attachment(id) == nil)
        #expect(undo.undoActionName == "Delete Note")
        undo.undo() // Delete Note
        #expect(model.attachment(id) != nil)
        undo.undo() // Edit Note
        #expect(text(model, id) == "Keep me")
        #expect(iconCount(model, topic) == 1)
    }

    @Test func explicitDeleteIsOneUndoableStep() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addNote(to: topic, text: "Body", undoManager: undo))
        #expect(model.deleteAttachment(id, undoManager: undo))
        #expect(undo.undoActionName == "Delete Note")
        #expect(model.attachment(id) == nil)
        undo.undo()
        #expect(text(model, id) == "Body")
        // A draft is just dropped.
        let draft = try #require(model.startNote(on: topic))
        let steps = undo.undoActionName
        #expect(model.deleteAttachment(draft, undoManager: undo))
        #expect(model.attachment(draft) == nil)
        #expect(undo.undoActionName == steps)
        #expect(MindMapModel.deleteActionName(for: .drawing) == "Delete Handwritten Note")
        #expect(MindMapModel.deleteActionName(for: .file) == "Delete File")
    }

    @Test func filesAreNeverDiscardedAsEmpty() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let file = Attachment.file(originalName: "empty.txt")
        #expect(model.addAttachment(file, to: topic, content: Data(), undoManager: undo))
        #expect(!model.discardIfEmpty(file.id, undoManager: undo))
        #expect(model.attachment(file.id) != nil)
        #expect(iconCount(model, topic) == 1)
    }

    @Test func draftTitleRenameAndNumbering() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let first = try #require(model.startNote(on: topic))
        let second = try #require(model.startNote(on: topic))
        #expect(model.attachment(second)?.title == "Note 2")
        #expect(model.renameAttachment(first, to: "Plan", undoManager: undo))
        #expect(model.attachment(first)?.title == "Plan")
        #expect(!undo.canUndo)
        #expect(model.setAttachmentContent(MarkdownNote.data("x"), for: first, undoManager: undo))
        #expect(model.map.node(withID: topic)?.attachments.first?.title == "Plan")
    }

    @Test func draftOfDeletedTopicIsDropped() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.startNote(on: topic))
        #expect(model.delete(topic, undoManager: undo))
        #expect(!model.setAttachmentContent(MarkdownNote.data("late"), for: id, undoManager: undo))
        #expect(model.attachment(id) == nil)
        #expect(model.startNote(on: UUID()) == nil)
    }

    @Test func drawingDraftLifecycle() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let empty = try #require(model.startDrawing(on: topic))
        #expect(model.attachment(empty)?.title == "Handwritten Note")
        #expect(model.setAttachmentContent(HandwrittenNote.emptyData, for: empty, actionName: "Draw",
                                           coalescing: false, undoManager: undo))
        #expect(model.isDraft(empty))
        #expect(model.discardIfEmpty(empty, undoManager: undo))
        #expect(!undo.canUndo)

        let id = try #require(model.startDrawing(on: topic))
        let drawing = DebugDrawing.sample()
        #expect(model.setAttachmentContent(drawing.dataRepresentation(), for: id, actionName: "Draw",
                                           coalescing: false, undoManager: undo))
        #expect(undo.undoActionName == "Add Handwritten Note")
        #expect(iconCount(model, topic) == 1)
        // Every stroke erased, then closed: deleted (undoable).
        #expect(model.setAttachmentContent(PKDrawing().dataRepresentation(), for: id, actionName: "Draw",
                                           coalescing: false, undoManager: undo))
        #expect(iconCount(model, topic) == 0)
        #expect(model.discardIfEmpty(id, undoManager: undo))
        #expect(undo.undoActionName == "Delete Handwritten Note")
        undo.undo()
        undo.undo()
        #expect(HandwrittenNote.drawing(model.content(of: id)).strokes.count == drawing.strokes.count)
    }

    @Test func editorOpensDraftAndReusesIt() throws {
        let (model, topic) = makeModel()
        let editor = EditorController(model: model)
        let undo = makeUndo()
        editor.undoManager = undo
        editor.addNote(to: topic)
        let id = try #require(editor.presentedAttachment?.attachmentID)
        #expect(model.isDraft(id))
        #expect(editor.firstNote(of: topic)?.id == id)
        editor.presentedAttachment = nil
        editor.openOrAddNote(topic)
        #expect(editor.presentedAttachment?.attachmentID == id)
        #expect(model.drafts(of: topic).count == 1)
        #expect(!undo.canUndo)
        #expect(model.discardIfEmpty(id, undoManager: undo))
        #expect(editor.firstNote(of: topic) == nil)
    }
}
