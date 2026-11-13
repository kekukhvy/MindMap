import Foundation
import SwiftUI
import Testing
@testable import MindMap

/// Note preview fidelity (tables, setext headings, nested quotes, task
/// variants, images) and dragging attachment icons to reorder them.
struct NotePreviewAndIconTests {
    @Test func noteWithTextOpensInPreview() {
        #expect(MarkdownNoteEditor.opensInPreview("# Plan\n- tea"))
        #expect(!MarkdownNoteEditor.opensInPreview(""))
        #expect(!MarkdownNoteEditor.opensInPreview(" \n\t"))
    }

    @Test func tablesAndHeadingVariants() {
        let markdown = """
        Title
        =====
        Section
        -------
        ## Closed ##
        | Name | Qty | Price |
        |:-----|:---:|------:|
        | Tea  | 2 | 3.50 |
        | Cake |
        after
        """
        let blocks = MarkdownBlock.parse(markdown)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Section"),
            .heading(level: 2, text: "Closed"),
            .table(header: ["Name", "Qty", "Price"], alignments: [.leading, .center, .trailing],
                   rows: [["Tea", "2", "3.50"], ["Cake", "", ""]]),
            .paragraph("after"),
        ])
    }

    @Test func listsQuotesFencesAndRules() {
        let markdown = "* [ ] open\n+ [X] closed\n\t- nested\n2) second\n>> deep\n~~~\na | b\n~~~\n***\nplain | text"
        #expect(MarkdownBlock.parse(markdown) == [
            .task(done: false, text: "open", indent: 0),
            .task(done: true, text: "closed", indent: 0),
            .bullet(text: "nested", indent: 1),
            .numbered(marker: "2)", text: "second", indent: 0),
            .quote("deep", level: 2),
            .code("a | b"),
            .rule,
            .paragraph("plain | text"),
        ])
    }

    @Test func imagesShowTheirAltText() {
        #expect(MarkdownBlock.inlineSource("See ![diagram](x.png) and ![](y.png).") == "See 🖼 diagram and 🖼 image.")
        #expect(MarkdownBlock.inlineSource("**bold** [link](https://a.b)") == "**bold** [link](https://a.b)")
    }

    @MainActor @Test func previewRendersTablesWithoutCrashing() {
        let view = MarkdownPreview(text: "# Plan\n| a | b |\n|---|---|\n| 1 | 2 |\n> quote\n- [x] done")
            .frame(width: 400, height: 300)
        let renderer = ImageRenderer(content: view)
        #expect(renderer.cgImage != nil)
    }

    @Test func dropSlotFollowsTheDragDistance() {
        #expect(AttachmentIconRow.targetSlot(from: 0, translation: 0, stride: 20, count: 3) == 0)
        #expect(AttachmentIconRow.targetSlot(from: 0, translation: 11, stride: 20, count: 3) == 1)
        #expect(AttachmentIconRow.targetSlot(from: 0, translation: 39, stride: 20, count: 3) == 2)
        #expect(AttachmentIconRow.targetSlot(from: 0, translation: 200, stride: 20, count: 3) == 2)
        #expect(AttachmentIconRow.targetSlot(from: 2, translation: -25, stride: 20, count: 3) == 1)
        #expect(AttachmentIconRow.targetSlot(from: 1, translation: -90, stride: 20, count: 3) == 0)
    }

    @Test @MainActor func draggingAnIconReordersInOneUndoStep() throws {
        let topic = Node(text: "Files")
        let model = MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap, children: [topic])))
        let editor = EditorController(model: model)
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        let a = try #require(model.addNote(to: topic.id, text: "a", undoManager: nil))
        let b = try #require(model.addNote(to: topic.id, text: "b", undoManager: nil))
        let c = try #require(model.addNote(to: topic.id, text: "c", undoManager: nil))
        let summaries = try #require(editor.scene.nodes[topic.id]?.attachments)
        #expect(AttachmentIconRow.isReorderable(summaries))
        editor.moveAttachmentIcon(a, toSlot: 2, on: topic.id)
        #expect(model.map.node(withID: topic.id)?.attachments.map(\.id) == [b, c, a])
        #expect(undo.undoActionName == "Move Attachment")
        editor.moveAttachmentIcon(a, toSlot: 0, on: topic.id)
        #expect(model.map.node(withID: topic.id)?.attachments.map(\.id) == [a, b, c])
        // Same slot: nothing happens.
        editor.moveAttachmentIcon(b, toSlot: 1, on: topic.id)
        undo.undo()
        #expect(model.map.node(withID: topic.id)?.attachments.map(\.id) == [b, c, a])
        // More than 3 attachments collapse to one icon per kind: no drag.
        _ = model.addNote(to: topic.id, text: "d", undoManager: nil)
        #expect(!AttachmentIconRow.isReorderable(try #require(editor.scene.nodes[topic.id]?.attachments)))
    }
}
