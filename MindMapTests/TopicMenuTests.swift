import Foundation
import Testing
@testable import MindMap

/// Task ▸ / Link ▸ / Note ▸ / Attachments ▸ (`TopicMenus`): the one menu
/// description the context menu, the iPad palette "More" and the Topic
/// menu bar all render.
@MainActor
struct TopicMenuTests {
    @MainActor private struct Fixture {
        let plain = Node(text: "Plain")
        var task = Node(text: "Task", task: TaskInfo(priority: .high))
        var linked = Node(text: "Linked")
        var mapLinked = Node(text: "Map linked")
        let map: MindMap
        let editor: EditorController
        let undo = UndoTests.makeUndoManager()

        init() {
            linked.link = .topic(plain.id)
            mapLinked.link = .map(MapReference(relativePath: "Other.mindmap", displayName: "Other"))
            map = MindMap(root: Node(text: "Central", children: [plain, task, linked, mapLinked]))
            editor = EditorController(model: MindMapModel(map: map))
            editor.undoManager = undo
        }
    }

    private func outline(_ submenu: TopicSubmenu) -> [String] { submenu.entries.map(\.outline) }

    private func entry(_ submenu: TopicSubmenu, _ title: String) throws -> TopicMenuEntry {
        try #require(submenu.entries.first { $0.title == title })
    }

    @Test func fourParallelSubmenusInOrder() {
        let f = Fixture()
        let menus = TopicMenus.all(f.editor.menuFacts(for: f.plain.id))
        #expect(menus.map(\.title) == ["Task", "Link", "Note", "Attachments"])
        #expect(menus.allSatisfy { $0.isEnabled })
    }

    @Test func taskSubmenuStructure() throws {
        let f = Fixture()
        let plain = TopicMenus.task(f.editor.menuFacts(for: f.plain.id))
        #expect(outline(plain) == ["Convert to Task", "Mark as Done", "Priority ▸", "Due Date ▸", "-",
                                   "Convert to Topic"])
        #expect(try entry(plain, "Convert to Task").isEnabled)
        #expect(try entry(plain, "Mark as Done").shortcut == .commandReturn)
        #expect(try !entry(plain, "Mark as Done").isEnabled)
        #expect(try !entry(plain, "Priority").isEnabled && !entry(plain, "Convert to Topic").isEnabled)

        let task = TopicMenus.task(f.editor.menuFacts(for: f.task.id))
        #expect(outline(task) == outline(plain)) // same structure, other items enabled
        #expect(try !entry(task, "Convert to Task").isEnabled && entry(task, "Convert to Topic").isEnabled)
        guard case let .submenu(priorities) = try entry(task, "Priority").kind else {
            Issue.record("Priority is not a submenu")
            return
        }
        #expect(priorities.map(\.outline) == ["High  !!!", "Medium  !!", "Low  !", "-", "None"])
        #expect(priorities.first?.isChecked == true)
        guard case let .submenu(dues) = try entry(task, "Due Date").kind else {
            Issue.record("Due Date is not a submenu")
            return
        }
        #expect(dues.map(\.outline) == ["Today", "Tomorrow", "Next Week", "-", "Choose Date…", "Clear Due Date"])
    }

    @Test func linkSubmenuStructure() throws {
        let f = Fixture()
        let none = TopicMenus.link(f.editor.menuFacts(for: f.plain.id))
        #expect(outline(none) == ["Add Link…", "Go to Link", "Copy Link", "-", "Remove Link"])
        #expect(try entry(none, "Add Link…").shortcut == .commandK)
        #expect(try !entry(none, "Go to Link").isEnabled && !entry(none, "Remove Link").isEnabled)

        let topic = TopicMenus.link(f.editor.menuFacts(for: f.linked.id))
        #expect(outline(topic) == ["Edit Link…", "Go to “Plain”", "Copy Link", "-", "Remove Link"])
        #expect(topic.entries.allSatisfy { $0.kind == .divider || $0.isEnabled })

        let map = TopicMenus.link(f.editor.menuFacts(for: f.mapLinked.id))
        #expect(outline(map) == ["Edit Link…", "Open “Other”", "Copy Link", "Locate…", "-", "Remove Link"])
    }

    @Test func noteAndAttachmentSubmenus() throws {
        let f = Fixture()
        let note = TopicMenus.note(f.editor.menuFacts(for: f.plain.id))
        #expect(outline(note) == ["Add Note", "Add Another Note", "Lock Note", "-", "Delete Note"])
        #expect(try !entry(note, "Lock Note").isEnabled)
        #expect(try entry(note, "Add Note").shortcut == .shiftCommandN)
        #expect(try !entry(note, "Delete Note").isEnabled)
        let attachments = TopicMenus.attachments(f.editor.menuFacts(for: f.plain.id))
        #expect(outline(attachments) == ["Add Handwritten Note", "Add Another Handwritten Note", "Attach File…",
                                         "Paste File"])

        // With a note: Open Note, Delete Note removes it (one step), the
        // note is listed under Attachments.
        f.editor.model.addNote(to: f.plain.id, text: "Hello", undoManager: f.undo)
        let facts = f.editor.menuFacts(for: f.plain.id)
        #expect(outline(TopicMenus.note(facts)) == ["Open Note", "Add Another Note", "Lock Note", "-", "Delete Note"])
        #expect(outline(TopicMenus.attachments(facts)).suffix(2) == ["-", "Note ▸"])
        // Lock Note (WP12) is a request for the document's lock gate.
        let noteID = try #require(f.editor.attachments(of: f.plain.id).first?.id)
        #expect(facts.attachments.first?.lockActions == [.lock(noteID)])
        f.editor.performMenuAction(.noteLock(.lock(noteID)), on: f.plain.id)
        #expect(f.editor.model.lock.request == .lockNote(noteID))
        f.editor.model.lock.request = nil
        f.editor.performMenuAction(.deleteNote, on: f.plain.id)
        #expect(f.editor.attachments(of: f.plain.id).isEmpty)
        f.undo.undo()
        #expect(f.editor.attachments(of: f.plain.id).count == 1)
    }

    @Test func multiSelectionTaskAppliesToAllLinkIsDisabled() throws {
        let f = Fixture()
        f.editor.setSelection([f.plain.id, f.task.id, f.linked.id], primary: f.task.id)
        let facts = f.editor.menuFacts(for: f.task.id)
        #expect(facts.count == 3)
        let menus = TopicMenus.all(facts)
        #expect(menus.map(\.isEnabled) == [true, false, false, false])
        let task = TopicMenus.task(facts)
        #expect(try entry(task, "Convert to Task").isEnabled && entry(task, "Convert to Topic").isEnabled)
        #expect(try entry(task, "Priority").isEnabled)

        // Convert all, then one Priority step for all three.
        f.editor.performMenuAction(.convertToTask, on: f.task.id)
        #expect(f.editor.model.map.allTasks.count == 3)
        f.editor.performMenuAction(.setPriority(.low), on: f.task.id)
        for id in [f.plain.id, f.task.id, f.linked.id] {
            #expect(f.editor.task(of: id)?.priority == .low)
        }
        #expect(f.editor.menuFacts(for: f.task.id).commonPriority == .low)
        f.editor.performMenuAction(.setDue(.tomorrow), on: f.task.id)
        #expect([f.plain.id, f.task.id, f.linked.id].allSatisfy { f.editor.task(of: $0)?.dueDate != nil })
        f.undo.undo() // due dates
        #expect(f.editor.task(of: f.plain.id)?.priority == .low)
        #expect(f.editor.task(of: f.task.id)?.dueDate == nil)
        f.undo.undo() // priorities: one step
        #expect(f.editor.task(of: f.task.id)?.priority == .high)
        #expect(f.editor.task(of: f.plain.id)?.priority == nil)
        #expect(f.editor.model.map.allTasks.count == 3)

        // ⌘K / ⇧⌘N do nothing on a multi-selection (their submenus are disabled).
        #expect(!f.editor.perform(.editLink))
        #expect(!f.editor.perform(.note))
        #expect(f.editor.linkEditor == nil)
    }

    @Test func menuBarStateCarriesTheSameFacts() {
        let f = Fixture()
        f.editor.select(f.linked.id)
        #expect(f.editor.commandState.menu == f.editor.menuFacts(for: f.linked.id))
        f.editor.select(nil)
        #expect(f.editor.commandState.menu.count == 0)
        #expect(TopicMenus.all(f.editor.commandState.menu).allSatisfy { !$0.isEnabled })
    }
}
