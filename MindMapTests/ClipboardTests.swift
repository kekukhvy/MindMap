import CoreGraphics
import Foundation
import Testing
@testable import MindMap
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Copy / cut / paste of topics: subtrees with styles, tasks, links,
/// attachments, inner relationships and boundaries; plain-text outline.
@MainActor
@Suite(.serialized)
final class ClipboardTests {
    deinit {
        #if os(macOS)
        TopicPasteboard.board = .general
        #else
        TopicPasteboard.board = .general
        #endif
    }

    /// Private pasteboard per test (never the user's clipboard).
    private func useTestPasteboard() {
        #if os(macOS)
        TopicPasteboard.board = NSPasteboard(name: NSPasteboard.Name("MindMapTests.\(UUID().uuidString)"))
        #else
        TopicPasteboard.board = UIPasteboard.withUniqueName()
        #endif
    }

    private struct Fixture {
        var model: MindMapModel
        var undo: UndoManager
        var a: UUID, a1: UUID, a2: UUID, b: UUID
        var noteID: UUID, noteFile: String
    }

    /// root → A (A1 [task, link→A2, note], A2), B; relationship A1→A2,
    /// boundary around A2, relationship A1→B (crosses out of A).
    private func fixture() -> Fixture {
        let a2 = Node(text: "A2", colorTag: .blue)
        let a1 = Node(text: "A1", shape: .capsule, link: .topic(a2.id), task: TaskInfo(priority: .high))
        let a = Node(text: "A", children: [a1, a2])
        let b = Node(text: "B")
        var map = MindMap(root: Node(text: "Root", layoutStyle: .rightMap, children: [a, b]))
        map.relationships = [Relationship(from: a1.id, to: a2.id, label: "inside"),
                             Relationship(from: a1.id, to: b.id, label: "out")]
        map.boundaries = [Boundary(memberIDs: [a2.id], label: "group")]
        let model = MindMapModel(map: map)
        let undo = UndoTests.makeUndoManager()
        let note = Attachment(kind: .markdown, title: "Note")
        model.addAttachment(note, to: a1.id, content: Data("# Hello".utf8), undoManager: nil)
        return Fixture(model: model, undo: undo, a: a.id, a1: a1.id, a2: a2.id, b: b.id, noteID: note.id,
                       noteFile: note.fileName)
    }

    @Test func clipboardKeepsInnerItemsAndBytes() throws {
        let f = fixture()
        let clip = try #require(f.model.clipboard(for: [f.a1, f.a]))
        #expect(clip.topics.map(\.id) == [f.a]) // A1 is inside A
        #expect(clip.relationships.map(\.label) == ["inside"])
        #expect(clip.boundaries.count == 1)
        #expect(clip.files[f.noteFile] == Data("# Hello".utf8))
        let decoded = try #require(TopicClipboard.decode(try clip.encoded()))
        #expect(decoded == clip)
        #expect(clip.plainText == "A\n\tA1\n\tA2")
    }

    @Test func pasteMakesFreshCopiesInOneUndoStep() throws {
        let f = fixture()
        let clip = try #require(f.model.clipboard(for: [f.a]))
        let ids = f.model.paste(clip, into: f.b, undoManager: f.undo)
        #expect(ids.count == 1)
        let copy = try #require(f.model.map.node(withID: ids[0]))
        #expect(copy.text == "A" && copy.id != f.a)
        let c1 = copy.children[0], c2 = copy.children[1]
        #expect(c1.text == "A1" && c1.id != f.a1 && c1.shape == .capsule && c1.task?.priority == .high)
        // The topic link inside the copy points at the copied target.
        #expect(c1.link == .topic(c2.id))
        let attachment = try #require(c1.attachments.first)
        #expect(attachment.id != f.noteID && attachment.fileName != f.noteFile)
        #expect(f.model.content(of: attachment.id) == Data("# Hello".utf8))
        let rels = f.model.map.relationships.filter { $0.fromNodeID == c1.id }
        #expect(rels.count == 1 && rels[0].toNodeID == c2.id && rels[0].label == "inside")
        #expect(f.model.map.boundaries.contains { $0.memberIDs == [c2.id] && $0.label == "group" })
        #expect(f.model.map.node(withID: f.a)?.children.count == 2) // original untouched
        #expect(f.undo.undoActionName == "Paste Topic")
        f.undo.undo()
        #expect(f.model.map.node(withID: ids[0]) == nil)
        #expect(f.model.map.relationships.count == 2 && f.model.map.boundaries.count == 1)
        f.undo.redo()
        #expect(f.model.map.node(withID: ids[0]) != nil)
    }

    @Test func pasteWithoutParentMakesFloatingTopicsAndRootCopyBecomesATopic() throws {
        let f = fixture()
        let clip = try #require(f.model.clipboard(for: [f.model.root.id]))
        let ids = f.model.paste(clip, into: nil, at: CGPoint(x: 300, y: 200), undoManager: f.undo)
        let floating = try #require(f.model.map.floatingTopics.first { $0.id == ids.first })
        #expect(floating.position == CGPoint(x: 300, y: 200))
        #expect(floating.node.text == "Root" && floating.node.children.count == 2)
        // Pasting the central topic's copy into a topic works too.
        let nested = f.model.paste(clip, into: f.b, undoManager: f.undo)
        #expect(f.model.map.parentID(of: nested[0]) == f.b)
    }

    @Test func cutIsOneStepAndPasteBringsTheBranchBack() throws {
        useTestPasteboard()
        let f = fixture()
        let editor = EditorController(model: f.model)
        editor.undoManager = f.undo
        editor.setSelection([f.a2, f.b], primary: f.a2)
        #expect(editor.cutSelection())
        #expect(f.model.map.node(withID: f.a2) == nil && f.model.map.node(withID: f.b) == nil)
        #expect(f.undo.undoActionName == "Cut Topics")
        editor.select(f.a1)
        #expect(editor.paste())
        let pasted = f.model.map.node(withID: f.a1)?.children.map(\.text)
        #expect(pasted == ["A2", "B"])
        #expect(editor.selectedIDs.count == 2)
        // Central topic alone cannot be cut, but can be copied.
        editor.select(f.model.root.id)
        #expect(!editor.canCutTopics)
        #expect(editor.copySelection())
        #expect(TopicPasteboard.readTopics()?.topics.first?.text == "Root")
        #expect(TopicPasteboard.readText()?.hasPrefix("Root\n\tA") == true)
    }

    @Test func lockedNotesAreNotCopied() throws {
        let f = fixture()
        var clip = try #require(f.model.clipboard(for: [f.a1]))
        clip.topics[0].attachments[0].lockKeyID = UUID()
        let instance = clip.instantiate()
        #expect(instance.topics[0].attachments.isEmpty)
        #expect(instance.files.isEmpty)
    }

    @Test func plainTextBecomesTopics() throws {
        let text = """
        Plan
        \tResearch
        \t\t- [ ] Interviews
        \t\t- [x] Survey
          Design
        • Launch
        1. Retro
        """
        let clip = try #require(TopicClipboard(plainText: text))
        #expect(clip.topics.map(\.text) == ["Plan", "Launch", "Retro"])
        let plan = clip.topics[0]
        #expect(plan.children.map(\.text) == ["Research", "Design"])
        #expect(plan.children[0].children.map(\.text) == ["Interviews", "Survey"])
        #expect(plan.children[0].children.map { $0.task?.isDone } == [false, true])
        #expect(TopicClipboard(plainText: "  \n\n") == nil)
        #expect(TopicClipboard(plainText: "One line")?.topics.map(\.text) == ["One line"])
    }

    @Test func pastingTextFromAnotherAppAddsChildren() throws {
        useTestPasteboard()
        let f = fixture()
        let editor = EditorController(model: f.model)
        editor.undoManager = f.undo
        #if os(macOS)
        TopicPasteboard.board.clearContents()
        TopicPasteboard.board.setString("Milk\nEggs", forType: .string)
        #else
        TopicPasteboard.board.string = "Milk\nEggs"
        #endif
        editor.select(f.b)
        #expect(editor.canPaste)
        #expect(editor.perform(.paste) || editor.paste())
        #expect(f.model.map.node(withID: f.b)?.children.map(\.text) == ["Milk", "Eggs"])
        #expect(f.undo.undoActionName == "Paste Topics")
    }

    @Test func readOnlyMapRefusesCutAndPasteButCopies() throws {
        useTestPasteboard()
        let f = fixture()
        let editor = EditorController(model: f.model)
        editor.undoManager = f.undo
        editor.setReadOnly(true)
        editor.select(f.a)
        #expect(editor.copySelection())
        #expect(!editor.cutSelection())
        #expect(!editor.paste())
        #expect(f.model.map.node(withID: f.a) != nil)
        #expect(f.model.map.node(withID: f.a)?.children.count == 2)
    }

    #if os(iOS)
    @Test func hardwareKeyboardShortcutsOnIPad() {
        #expect(KeyCommandMap.command(key: "c", modifiers: .command, characters: "c") == .copy)
        #expect(KeyCommandMap.command(key: "x", modifiers: .command, characters: "x") == .cut)
        #expect(KeyCommandMap.command(key: "v", modifiers: .command, characters: "v") == .paste)
    }
    #endif
}
