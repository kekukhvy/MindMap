import Foundation
import SwiftUI
import Testing
@testable import MindMap

/// Find (⌘F): matching, wrap-around and the view-only filter.
@MainActor
struct FindTests {
    /// r -> a("Budget 2027") -> a1("Café") ; r -> b("Plain") ; floating f("Floating Invoice")
    private func makeModel(bText: String = "Plain") -> (MindMapModel, ids: [String: UUID]) {
        let a1 = Node(text: "Café"), a = Node(text: "Budget 2027", isCollapsed: true, children: [a1])
        let b = Node(text: bText)
        let f = Node(text: "Floating Invoice")
        let map = MindMap(root: Node(text: "r", children: [a, b]),
                          floatingTopics: [FloatingTopic(node: f, position: CGPoint(x: 0, y: 300))])
        return (MindMapModel(map: map), ["r": map.root.id, "a": a.id, "a1": a1.id, "b": b.id, "f": f.id])
    }

    private func topics(_ matches: [FindMatch], _ ids: [String: UUID]) -> [String] {
        matches.map { match in ids.first { $0.value == match.topicID }?.key ?? "?" }
    }

    // AC-find-1
    @Test func topicTextMatchIsCaseAndDiacriticInsensitive() {
        let (model, ids) = makeModel()
        #expect(topics(model.findMatches("budget"), ids) == ["a"])
        #expect(topics(model.findMatches("cafe"), ids) == ["a1"])
        #expect(model.findMatches("  ").isEmpty)
    }

    // AC-find-2
    @Test func markdownNoteTextIsMatchedAndMarkedAsNoteMatch() throws {
        let (model, ids) = makeModel()
        let note = try #require(model.addNote(to: ids["b"]!, text: "Intro\nPay the Invoice today", undoManager: nil))
        let match = try #require(model.findMatches("invoice").first { $0.topicID == ids["b"] })
        #expect(match.noteID == note)
        #expect(match.snippet == "Pay the Invoice today")
    }

    // AC-find-3
    @Test func lockedNoteIsNeverSearchedEvenWhenItsTextIsReadable() {
        var lockedNote = Attachment(kind: .markdown, title: "Secret")
        lockedNote.lockKeyID = UUID()
        let plain = Attachment(kind: .markdown, title: "Open")
        let map = MindMap(root: Node(text: "r", children: [Node(text: "x", attachments: [lockedNote]),
                                                           Node(text: "y", attachments: [plain])]))
        // The reader returns plaintext for every note, as an unlocked-in-session note would.
        let matches = map.findMatches("invoice") { _ in "my invoice" }
        #expect(matches.map(\.noteID) == [plain.id])
    }

    // AC-find-4
    @Test func floatingTopicIsMatched() {
        let (model, ids) = makeModel()
        #expect(topics(model.findMatches("invoice"), ids) == ["f"])
    }

    // AC-find-5
    @Test func nextWrapsFromLastToFirstAndPreviousFromFirstToLast() {
        let (model, ids) = makeModel(bText: "Plain Budget")
        let editor = EditorController(model: model)
        editor.openFind()
        editor.findQuery = "budget"
        #expect(topics(editor.findMatches, ids) == ["a", "b"] && editor.findIndex == 0)
        editor.stepFind(forward: true)
        #expect(editor.findIndex == 1)
        editor.stepFind(forward: true)
        #expect(editor.findIndex == 0)
        editor.stepFind(forward: false)
        #expect(editor.findIndex == 1)
    }

    // AC-find-6
    @Test func filterShowsMatchesAndAncestorsOnlyWithoutTouchingTheDocument() {
        let undo = UndoTests.makeUndoManager()
        let (model, ids) = makeModel()
        let before = model.map
        let editor = EditorController(model: model)
        editor.undoManager = undo
        let full = Set(editor.scene.nodes.keys)
        #expect(!full.contains(ids["a1"]!))  // collapsed under "a"

        editor.openFind()
        editor.findQuery = "cafe"
        // Match under a collapsed branch: shown with its ancestors; others hidden.
        #expect(Set(editor.scene.nodes.keys) == [ids["r"]!, ids["a"]!, ids["a1"]!])
        #expect(model.map == before)
        #expect(!undo.canUndo)

        editor.closeFind()
        #expect(Set(editor.scene.nodes.keys) == full)
        #expect(model.map == before)
        #expect(!undo.canUndo)
    }
}
