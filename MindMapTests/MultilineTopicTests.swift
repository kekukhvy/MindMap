import Foundation
import Testing
@testable import MindMap
#if os(iOS)
import UIKit
#endif

/// Multi-line topic text: Return commits, Shift/Option+Return = line break;
/// iPad keyboard keeps the edited topic visible; Tab bridge only while the
/// canvas has focus.
struct MultilineTopicTests {
    @Test func returnActionByModifiers() {
        #expect(TopicTextInput.returnAction(shift: false, option: false) == .commit)
        #expect(TopicTextInput.returnAction(shift: true, option: false) == .newline)
        #expect(TopicTextInput.returnAction(shift: false, option: true) == .newline)
        #expect(TopicTextInput.returnAction(shift: true, option: true) == .newline)
    }

    @Test func classifiesBareReturnInsertion() {
        #expect(TopicTextInput.classify(old: "ab", new: "ab\n", expectsNewline: false) == .returnPressed)
        #expect(TopicTextInput.classify(old: "ab", new: "a\nb", expectsNewline: false) == .returnPressed)
        // Return over a selection (all text selected) is still Return.
        #expect(TopicTextInput.classify(old: "Subtopic", new: "\n", expectsNewline: false) == .returnPressed)
        #expect(TopicTextInput.classify(old: "ab", new: "ab\n", expectsNewline: true) == .text("ab\n"))
        #expect(TopicTextInput.classify(old: "ab", new: "abc", expectsNewline: false) == .text("abc"))
        // Pasting several lines is typing.
        #expect(TopicTextInput.classify(old: "", new: "x\ny", expectsNewline: false) == .text("x\ny"))
        #expect(TopicTextInput.classify(old: "a\nb", new: "ab", expectsNewline: false) == .text("ab"))
    }

    @Test func insertedTextFindsTheReplacedRange() {
        #expect(TopicTextInput.insertedText(old: "abc", new: "abXc") == "X")
        #expect(TopicTextInput.insertedText(old: "aaa", new: "aaaa") == "a")
        #expect(TopicTextInput.insertedText(old: "abc", new: "abc") == "")
        #expect(TopicTextInput.insertedText(old: "hello", new: "h\n") == "\n")
    }

    @Test func committedTextTrimsOuterLineBreaksOnly() {
        #expect(TopicTextInput.committed("\nTwo\nlines\n\n") == "Two\nlines")
        #expect(TopicTextInput.committed("a\r\nb\rc") == "a\nb\nc")
        #expect(TopicTextInput.committed("  spaced  ") == "  spaced  ")
        #expect(TopicTextInput.singleLine("First\n second \n\nthird") == "First second third")
    }

    private func editor(_ text: String = "Topic") -> (EditorController, UUID, UndoManager) {
        let topic = Node(text: text)
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "r", layoutStyle: .rightMap,
                                                                                   children: [topic]))))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.select(topic.id)
        editor.beginEditing()
        return (editor, topic.id, undo)
    }

    @Test @MainActor func shiftReturnKeepsALineBreakAndReturnCommits() async throws {
        let (editor, id, undo) = editor()
        editor.updateDraft("First", editing: id)
        // Shift+Return: the field is asked for a line break → typing.
        #expect(editor.handleEditorReturn(shift: true, option: false, editing: id))
        editor.updateDraft("First\n", editing: id)
        editor.updateDraft("First\nSecond", editing: id)
        #expect(editor.editingID == id)
        #expect(editor.expectedNewlines == 0)
        // Plain Return commits, nothing inserted.
        #expect(!editor.handleEditorReturn(shift: false, option: false, editing: id))
        #expect(editor.editingID == nil)
        #expect(editor.model.map.node(withID: id)?.text == "First\nSecond")
        undo.undo()
        #expect(editor.model.map.node(withID: id)?.text == "Topic")
    }

    @Test @MainActor func bareReturnFromTheSoftwareKeyboardCommits() async throws {
        let (editor, id, _) = editor()
        editor.updateDraft("Plan", editing: id)
        editor.updateDraft("Plan\n", editing: id)
        #expect(editor.draftText == "Plan")
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.editingID == nil)
        #expect(editor.model.map.node(withID: id)?.text == "Plan")
    }

    @Test @MainActor func multiLineTopicGrowsAndExports() throws {
        let (editor, id, _) = editor()
        let single = try #require(editor.scene.layout.frames[id])
        #expect(editor.handleEditorReturn(shift: false, option: true, editing: id))
        editor.updateDraft("Topic\n", editing: id)
        editor.updateDraft("Topic\nline two", editing: id)
        let editing = try #require(editor.scene.layout.frames[id])
        #expect(editing.height > single.height + 8)
        editor.commitEditing()
        let committed = try #require(editor.scene.layout.frames[id])
        #expect(abs(committed.height - editing.height) < 0.5)
        // One-line places (Markdown export bullets, link lists) join the lines.
        let markdown = MarkdownExport.markdown(of: editor.model.map, title: "T", noteText: { _ in nil })
        #expect(markdown.contains("Topic line two"))
        #expect(LinkCandidate.displayText("Topic\nline two") == "Topic")
    }

    /// iPad software keyboard: the canvas shrinks; the edited topic near the
    /// bottom edge is scrolled above it (same for a relationship label).
    @Test @MainActor func shrinkingCanvasWhileEditingRevealsTheTopic() throws {
        let (editor, id, _) = editor()
        editor.updateViewSize(CGSize(width: 800, height: 700))
        let frame = try #require(editor.scene.layout.frames[id])
        // Put the topic 40 pt above the bottom edge.
        editor.viewport.offset.y += 700 - 40 - editor.viewport.toScreen(frame).maxY
        editor.updateViewSize(CGSize(width: 800, height: 400))
        let screen = editor.viewport.toScreen(frame)
        #expect(screen.maxY <= 400 - 23)
        #expect(screen.minY >= 0)
        // Not editing: resize keeps the content center (no reveal).
        editor.commitEditing()
        let before = editor.viewport
        editor.updateViewSize(CGSize(width: 800, height: 300))
        #expect(abs(editor.viewport.offset.y - (before.offset.y - 50)) < 0.01)
    }

    #if os(iOS)
    @Test @MainActor func tabCommandOnlyWhileActive() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let bridge = TabKeyBridge.BridgeView()
        bridge.isActive = false
        root.view.addSubview(bridge)
        #expect(!bridge.isCommandInstalled)
        bridge.isActive = true
        #expect(bridge.isCommandInstalled)
        #expect(root.keyCommands?.filter { $0.input == "\t" }.count == 1)
        bridge.isActive = false
        #expect(!bridge.isCommandInstalled)
        #expect(root.keyCommands?.contains { $0.input == "\t" } != true)
        bridge.removeFromSuperview()
        window.isHidden = true
    }
    #endif
}
