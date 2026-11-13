#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MindMap

/// Find bar in a real window (`CanvasEventHarness`: the real SwiftUI
/// canvas with its key handling): keys typed into the find field edit the
/// query only, they never reach the topic shortcuts (type to rename,
/// Backspace = delete, arrows = select, Return = add sibling).
@MainActor
@Suite(.serialized)
struct FindWindowEventTests {
    private static let backspace: (characters: String, keyCode: UInt16) = ("\u{7F}", 51)
    private static let returnKey: (characters: String, keyCode: UInt16) = ("\r", 36)
    private static let downArrow: (characters: String, keyCode: UInt16) = ("\u{F701}", 125)

    // AC-find-fix-1
    @Test func keysTypedIntoTheFindFieldOnlyEditTheQuery() async throws {
        let cafe = Node(text: "Café"), plain = Node(text: "Plain")
        let map = MindMap(root: Node(text: "r", layoutStyle: .rightMap,
                                     children: [Node(text: "Budget", children: [cafe]), plain]))
        let harness = try await CanvasEventHarness(map: map)
        defer { harness.close() }
        let editor = harness.editor
        let topicCount = map.root.allNodes.count
        editor.openFind()
        try await harness.wait(300)

        // "caf" finds and selects "Café"; the next key still goes to the field.
        try await harness.typeText("cafe")
        #expect(editor.findQuery == "cafe")
        #expect(editor.selectedID == cafe.id)
        #expect(editor.editingID == nil)
        #expect(editor.model.map.node(withID: cafe.id)?.text == "Café")

        try await harness.key(Self.backspace.characters, keyCode: Self.backspace.keyCode)
        #expect(editor.findQuery == "caf")
        #expect(editor.model.map.root.allNodes.count == topicCount)

        try await harness.key(Self.downArrow.characters, keyCode: Self.downArrow.keyCode)
        #expect(editor.selectedID == cafe.id)

        // Return steps to the next match; the field keeps focus (AppKit
        // selects its text, so the next key replaces the phrase).
        try await harness.key(Self.returnKey.characters, keyCode: Self.returnKey.keyCode)
        #expect(editor.findQuery == "caf")
        #expect(editor.isFindFieldFocused)
        #expect(harness.window.firstResponder is NSText)
        try await harness.typeText("e")
        #expect(editor.findQuery.hasSuffix("e"))
        #expect(editor.editingID == nil)
        #expect(editor.model.map.root.allNodes.count == topicCount)
        #expect(editor.model.map.node(withID: cafe.id)?.text == "Café")
    }
}
#endif
