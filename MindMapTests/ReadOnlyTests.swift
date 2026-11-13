import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import MindMap

/// WP15 "Lock Editing": the central read-only gate (every menu action,
/// keyboard command, palette button, gesture entry point and model API is
/// refused without changing the map), what stays allowed (select, fold,
/// links, opening notes, Tasks panel navigation), the notice, persistence
/// + library sync, undo safety and anchored undo of expand / collapse.
@MainActor
private final class LockFixture {
    let rootID = UUID(), alpha = UUID(), alpha1 = UUID(), alpha2 = UUID(), beta = UUID(), gamma = UUID()
    let delta = UUID(), floating = UUID(), relationshipID = UUID(), boundaryID = UUID()
    let editor: EditorController
    let undo = UndoTests.makeUndoManager()
    var noteID: UUID!
    var emptyNoteID: UUID!
    var drawingID: UUID!
    /// Deferred palette / fold / notice work (run with `flush()`).
    var deferred: [() -> Void] = []
    var model: MindMapModel { editor.model }
    var map: MindMap { editor.model.map }

    init(locked: Bool = true) {
        var gammaNode = Node(id: gamma, text: "Gamma")
        gammaNode.task = TaskInfo(priority: .medium)
        let map = MindMap(
            root: Node(id: rootID, text: "Central", layoutStyle: .balancedMap, children: [
                Node(id: alpha, text: "Alpha", children: [Node(id: alpha1, text: "A1"), Node(id: alpha2, text: "A2")]),
                Node(id: beta, text: "Beta"),
                gammaNode,
                Node(id: delta, text: "Delta", link: .topic(alpha2)),
            ]),
            floatingTopics: [FloatingTopic(node: Node(id: floating, text: "Floating"), position: CGPoint(x: 0, y: 300))],
            relationships: [Relationship(id: relationshipID, from: alpha, to: beta, label: "uses")],
            boundaries: [Boundary(id: boundaryID, memberIDs: [gamma], label: "Box")])
        editor = EditorController(model: MindMapModel(map: map))
        editor.undoManager = undo
        editor.paletteScheduler = { [unowned self] _, work in self.deferred.append(work) }
        editor.noticeScheduler = { [unowned self] _, work in self.deferred.append(work) }
        editor.openURL = { _ in }
        editor.updateViewSize(CGSize(width: 1200, height: 800))
        noteID = model.addNote(to: beta, text: "Beta notes", undoManager: undo)
        emptyNoteID = model.addNote(to: gamma, text: "", undoManager: undo)
        drawingID = model.addDrawing(to: beta, undoManager: undo)
        // Fold Alpha so Go to / Show Topic has something to reveal.
        model.toggleCollapse(alpha, undoManager: undo)
        if locked { editor.setReadOnly(true) }
    }

    func flush() {
        let work = deferred
        deferred = []
        work.forEach { $0() }
    }

    /// The map without fold state (folding is allowed while locked).
    var content: MindMap { Self.content(of: map) }

    static func content(of map: MindMap) -> MindMap {
        func unfold(_ node: inout Node) {
            node.isCollapsed = false
            for index in node.children.indices { unfold(&node.children[index]) }
        }
        var map = map
        map.isReadOnly = false
        unfold(&map.root)
        for index in map.floatingTopics.indices { unfold(&map.floatingTopics[index].node) }
        if var panel = map.taskPanel {
            panel.isCollapsed = false
            map.taskPanel = panel.position == nil ? nil : panel
        }
        return map
    }

    var noteText: String { MarkdownNote.text(model.content(of: noteID)) }

    /// Runs `body` and expects the map's content, note bytes and drafts unchanged.
    func expectNoChange(_ label: String, _ body: () -> Void) {
        let before = content, text = noteText
        body()
        #expect(content == before, "\(label) changed the locked map")
        #expect(noteText == text, "\(label) changed a note")
        #expect(model.attachmentDrafts.isEmpty, "\(label) started a note")
        #expect(map.isReadOnly, "\(label) unlocked the map")
        editor.commitEditing()
    }

    /// Every button action of the four topic submenus (recursively).
    static func actions(_ entries: [TopicMenuEntry]) -> [(TopicMenuAction, Bool)] {
        entries.flatMap { entry -> [(TopicMenuAction, Bool)] in
            switch entry.kind {
            case .divider: return []
            case let .button(action): return [(action, entry.isEnabled)]
            case let .submenu(children): return actions(children).map { ($0.0, $0.1 && entry.isEnabled) }
            }
        }
    }
}

@MainActor
@Suite struct ReadOnlyGateTests {
    static let commands: [EditorCommand] = [
        .addChild, .addSibling, .delete, .edit, .editReplacing("x"), .toggleCollapse, .move(.up), .move(.down),
        .move(.left), .move(.right), .zoomIn, .zoomOut, .zoomToFit, .addRelationship, .addBoundary, .note,
        .handwrittenNote, .attachFile, .collapseToLevel(1), .expandAll, .editLink, .goBack, .toggleTaskDone,
        .selectAll, .cancel,
    ]

    @Test func everyKeyboardCommandLeavesTheContentAlone() {
        let f = LockFixture()
        for target in [f.rootID, f.alpha, f.beta, f.gamma, f.delta, f.floating] {
            for command in Self.commands {
                f.editor.select(target)
                f.editor.readOnlyNotice = nil
                f.expectNoChange("\(command) on \(target)") { f.editor.perform(command) }
                if command.isEdit { #expect(f.editor.readOnlyNotice != nil, "\(command) gave no notice") }
                #expect(f.editor.editingID == nil && f.editor.pickMode == nil && f.editor.linkEditor == nil)
                #expect(!f.editor.isFileImporterPresented)
            }
        }
        // A relationship / boundary selected: Delete / label edit refused too.
        for item in [CanvasItem.relationship(f.relationshipID), .boundary(f.boundaryID)] {
            for command in [EditorCommand.delete, .edit] {
                f.editor.selectItem(item)
                f.expectNoChange("\(command) on \(item)") { f.editor.perform(command) }
                #expect(f.editor.labelEditing == nil)
            }
        }
    }

    @Test func everyTopicMenuItemIsDisabledUnlessReadingAndRefusedAnyway() {
        let f = LockFixture()
        let unlocked = LockFixture(locked: false)
        for id in [f.rootID, f.alpha, f.beta, f.gamma, f.delta] {
            let facts = f.editor.menuFacts(for: id)
            #expect(facts.isReadOnly)
            let items = TopicMenus.all(facts).flatMap { LockFixture.actions($0.entries) }
            var openFacts = facts
            openFacts.isReadOnly = false
            let open = TopicMenus.all(openFacts).flatMap { LockFixture.actions($0.entries) }
            #expect(items.map(\.0) == open.map(\.0)) // same items, just disabled
            for (action, enabled) in items {
                if enabled { #expect(action.isAllowedWhileReadOnly(facts), "\(action) enabled while locked") }
                f.editor.select(id)
                f.expectNoChange("menu \(action) on \(id)") { f.editor.performMenuAction(action, on: id) }
                f.editor.presentedAttachment = nil
                f.editor.dueDatePickerID = nil
                #expect(f.editor.linkEditor == nil && !f.editor.isFileImporterPresented)
            }
            // Submenus with nothing left to do are disabled as a whole.
            for submenu in TopicMenus.all(facts) where !submenu.entries.contains(where: \.hasEnabledItem) {
                #expect(!submenu.isEnabled)
            }
        }
        // Tasks panel row menu: Task ▸ items all disabled.
        #expect(TopicMenus.taskEntries(f.editor.menuFacts(for: f.gamma)).allSatisfy { !$0.hasEnabledItem })
        // Multi-selection menus too.
        f.editor.setSelection([f.alpha, f.beta, f.gamma], primary: f.beta)
        for (action, _) in TopicMenus.all(f.editor.menuFacts(for: f.beta)).flatMap({ LockFixture.actions($0.entries) }) {
            f.expectNoChange("multi \(action)") { f.editor.performMenuAction(action, on: f.beta) }
            f.editor.presentedAttachment = nil
        }
        // The unlocked map has the edit items enabled (sanity).
        let doneItem = TopicMenus.task(unlocked.editor.menuFacts(for: unlocked.gamma)).entries[1]
        #expect(doneItem.title == "Mark as Done" && doneItem.isEnabled)
        #expect(!TopicMenus.task(f.editor.menuFacts(for: f.gamma)).entries[1].isEnabled)
    }

    @Test func everyPaletteButtonLeavesTheContentAlone() {
        let f = LockFixture()
        for id in [f.rootID, f.alpha, f.beta, f.delta] {
            f.editor.select(id)
            let items = ActionPaletteCatalog.items(for: f.editor.paletteContext)
            #expect(items.allSatisfy { !$0.action.isEdit }, "edit button in the read-only palette")
            for action in PaletteAction.allCases {
                f.editor.select(id)
                f.editor.palette.showForSelection()
                f.expectNoChange("palette \(action) on \(id)") { f.editor.performPaletteAction(action) }
                f.editor.presentedAttachment = nil
            }
        }
        f.editor.palette.showInsert(at: CGPoint(x: 300, y: 300))
        #expect(f.editor.paletteItems.isEmpty) // nothing to insert
        f.editor.expandAll()
        f.editor.setSelection([f.alpha, f.beta], primary: f.alpha)
        #expect(ActionPaletteCatalog.items(for: f.editor.paletteContext).map(\.action) == [.collapse, .more],
                "\(f.editor.paletteContext)")
    }

    @Test func gestureAndEditorEntryPointsAreRefused() {
        let f = LockFixture()
        let e = f.editor
        let point = CGPoint(x: 300, y: 300)
        f.expectNoChange("double-tap") {
            e.touchTapTopic(f.beta, at: point, time: 100)
            #expect(e.touchTapTopic(f.beta, at: point, time: 100.1) == .refused)
            f.flush()
        }
        f.expectNoChange("double-tap on a folded topic") {
            e.touchTapTopic(f.alpha, at: point, time: 200)
            e.touchTapTopic(f.alpha, at: point, time: 200.1)
            f.flush()
        }
        #expect(!e.showsAddChildHandle(f.beta))
        f.expectNoChange("+ handle") { e.tapAddChildHandle(f.beta) }
        e.select(f.beta)
        f.expectNoChange("Pencil double-tap") {
            for preference in [PencilPreference.switchEraser, .switchPrevious, .showColorPalette, .other] {
                e.pencilDoubleTap(preference: preference)
            }
        }
        #expect(e.scribbleTopics(inScreenRect: CGRect(x: -5000, y: -5000, width: 10000, height: 10000)).isEmpty)
        f.expectNoChange("Scribble") { e.beginScribble(on: f.beta) }
        #expect(e.editingID == nil)
        f.expectNoChange("drag / free move / floating move") {
            for (id, free) in [(f.beta, false), (f.beta, true), (f.floating, false), (f.alpha, false)] {
                e.updateDrag(id, translation: CGSize(width: 60, height: 140), location: point, freeMove: free)
                #expect(e.drag == nil)
                e.endDrag()
            }
        }
        f.expectNoChange("double-click / double-tap empty canvas") { e.addFloatingTopic(at: point) }
        f.expectNoChange("pick modes") {
            e.beginRelationship(from: f.alpha)
            e.beginLinkPick(for: f.alpha)
            e.beginAttach(f.floating)
            #expect(e.pickMode == nil)
            #expect(!e.completePick(f.beta))
        }
        f.expectNoChange("label / members / curve / panel / checkbox / due / link / files") {
            e.beginLabelEdit(.relationship(f.relationshipID))
            e.beginLabelEdit(.boundary(f.boundaryID))
            e.beginEditBoundaryMembers(f.boundaryID)
            e.updateControlDrag(f.relationshipID, isStart: true, translation: CGSize(width: 40, height: 40))
            e.endControlDrag()
            e.updateTaskPanelDrag(CGSize(width: 80, height: 40))
            e.endTaskPanelDrag()
            e.togglePanelTask(f.gamma)
            e.toggleTaskDone(f.gamma)
            e.beginDueDatePicker(f.gamma)
            e.beginEditLink(f.beta)
            e.beginAttachFile(to: f.beta)
            e.beginEditing(f.beta)
            e.detachAsFloating(f.alpha)
            e.rebalanceMap()
            e.resetPositions()
            e.setLayoutStyle(.treeDown, for: f.alpha)
            e.resetColor(f.alpha, wholeBranch: true)
            e.addNote(to: f.alpha)
            e.addDrawing(to: f.alpha)
            e.openOrAddNote(f.alpha) // no note there: would add one
            e.removeAttachment(f.noteID)
            e.moveAttachment(f.noteID, by: 1)
            e.addBoundaryFromSelection(f.beta)
            e.applyColorSheet(ColorSheetRequest(target: .theme, initialHex: "#123456"), hex: "#123456")
        }
        #expect(e.labelEditing == nil && e.boundaryMemberEditing == nil && e.controlDrag == nil)
        #expect(e.taskPanelDrag == nil && e.dueDatePickerID == nil && e.linkEditor == nil && e.editingID == nil)
        #expect(!e.isFileImporterPresented)
    }

    @Test func modelAPIRefusesEveryEditWhileLocked() throws {
        let f = LockFixture()
        let m = f.model, u = f.undo
        var handled: [String] = []
        m.readOnlyRejectionHandler = { handled.append($0) }
        let attempts: [(String, () -> Bool)] = [
            ("addChild", { m.addChild(to: f.beta, undoManager: u) != nil }),
            ("addSibling", { m.addSibling(after: f.beta, undoManager: u) != nil }),
            ("delete", { m.delete(f.beta, undoManager: u) }),
            ("delete many", { m.delete([f.beta, f.gamma], undoManager: u) }),
            ("reparent", { m.reparent(f.beta, to: f.gamma, undoManager: u) }),
            ("rename", { m.rename(f.beta, to: "B!", undoManager: u) }),
            ("addFloating", { m.addFloating(at: .zero, undoManager: u) != nil }),
            ("moveFloating", { m.moveFloating(f.floating, to: CGPoint(x: 9, y: 9), undoManager: u) }),
            ("setManualPosition", { m.setManualPosition(f.beta, to: CGPoint(x: 50, y: 50), undoManager: u) }),
            ("setColor", { m.setColor(f.beta, to: .red, undoManager: u) }),
            ("setShape", { m.setShape(.capsule, for: f.beta, undoManager: u) }),
            ("setTheme", { m.setTheme(.classic, undoManager: u) }),
            ("setLayoutStyle", { m.setLayoutStyle(.treeDown, for: f.beta, undoManager: u) }),
            ("addRelationship", { m.addRelationship(from: f.beta, to: f.gamma, undoManager: u) != nil }),
            ("removeRelationship", { m.removeRelationship(f.relationshipID, undoManager: u) }),
            ("relabelRelationship", { m.relabelRelationship(f.relationshipID, to: "x", undoManager: u) }),
            ("addBoundary", { m.addBoundary(members: [f.beta], undoManager: u) != nil }),
            ("removeBoundary", { m.removeBoundary(f.boundaryID, undoManager: u) }),
            ("setLink", { m.setLink(.web(URL(string: "https://example.com")!), for: f.beta, undoManager: u) }),
            ("removeLink", { m.removeLink(from: f.delta, undoManager: u) }),
            ("makeTask", { m.makeTask(f.beta, undoManager: u) }),
            ("toggleTaskDone", { m.toggleTaskDone(f.gamma, undoManager: u) }),
            ("setTaskPriority", { m.setTaskPriority(.high, for: f.gamma, undoManager: u) }),
            ("setTaskDueDate", { m.setTaskDueDate(Date(), for: f.gamma, undoManager: u) }),
            ("moveTaskPanel", { m.moveTaskPanel(to: CGPoint(x: 400, y: 0), undoManager: u) }),
            ("addNote", { m.addNote(to: f.alpha, undoManager: u) != nil }),
            ("startNote", { m.startNote(on: f.alpha) != nil }),
            ("setAttachmentContent", { m.setAttachmentContent(Data("changed".utf8), for: f.noteID, undoManager: u) }),
            ("renameAttachment", { m.renameAttachment(f.noteID, to: "Renamed", undoManager: u) }),
            ("removeAttachment", { m.removeAttachment(f.noteID, undoManager: u) }),
            ("moveAttachment", { m.moveAttachment(f.noteID, to: 1, undoManager: u) }),
            ("side (Rebalance)", { m.perform([.tree(.set(id: f.alpha, .side(.left)))], actionName: "Rebalance Map",
                                             undoManager: u) }),
        ]
        for (name, attempt) in attempts {
            f.expectNoChange(name) { #expect(!attempt(), "\(name) succeeded on a locked map") }
        }
        #expect(throws: LockError.notLockable) { try m.lockNote(f.noteID, undoManager: u) }
        #expect(handled.count >= attempts.count) // each refusal reported
        // Closing an empty note's viewer keeps it (no "Delete Note" on a locked map).
        #expect(!m.discardIfEmpty(f.emptyNoteID, undoManager: u))
        #expect(m.attachment(f.emptyNoteID) != nil)
        // Bookkeeping that is not a user edit still runs.
        #expect(m.bypassingReadOnly { m.rename(f.beta, to: "System", undoManager: nil) })
    }

    @Test func readingStillWorks() throws {
        let f = LockFixture()
        let e = f.editor
        f.expectNoChange("allowed actions") {
            // Select, multi-select, navigate, zoom.
            e.select(f.beta)
            e.move(.down)
            e.selectAllTopics()
            #expect(e.selectedIDs.count > 2)
            e.setSelection([f.beta, f.gamma], primary: f.gamma)
            #expect(e.selectedIDs == [f.beta, f.gamma])
            e.zoom(by: 1.5)
            e.zoomToFit()
            // Fold / unfold (one undo step each), levels, branches.
            e.toggleCollapse(f.alpha)
            #expect(e.model.map.node(withID: f.alpha)?.isCollapsed == false)
            e.collapseToLevel(1)
            #expect(e.model.map.node(withID: f.alpha)?.isCollapsed == true)
            e.expandAll()
            #expect(e.model.map.node(withID: f.alpha)?.isCollapsed == false)
            e.collapseBranch(f.alpha)
            e.expandBranch(f.alpha)
            #expect(f.undo.undoActionName == "Expand Branch")
            e.collapseBranch(f.alpha)
            // Go to a topic link inside the folded branch, then Back.
            e.goToLink(of: f.delta)
            #expect(e.selectedID == f.alpha2)
            #expect(e.model.map.node(withID: f.alpha)?.isCollapsed == false)
            e.goBack()
            #expect(e.selectedID == f.delta)
            e.copyLink(f.delta)
            // Open existing note / drawing read-only, from menus and palette.
            e.openOrAddNote(f.beta)
            #expect(e.presentedAttachment?.attachmentID == f.noteID)
            e.presentedAttachment = nil
            e.performMenuAction(.openOrAddDrawing, on: f.beta)
            #expect(e.presentedAttachment?.attachmentID == f.drawingID)
            e.presentedAttachment = nil
            e.select(f.beta)
            e.performPaletteAction(.note)
            #expect(e.presentedAttachment?.attachmentID == f.noteID)
            // Tasks panel: navigation and folding the panel.
            e.showTask(f.gamma)
            #expect(e.selectedID == f.gamma)
            e.toggleTaskPanelCollapsed()
            #expect(e.model.map.taskPanel?.isCollapsed == true)
            // iPad: tap folds a branch.
            e.touchTapTopic(f.alpha, at: CGPoint(x: 10, y: 10), time: 500)
            f.flush()
            #expect(e.model.map.node(withID: f.alpha)?.isCollapsed == true)
        }
        // The map's name is not content (library rename).
        #expect(f.model.setMapTitle("Read Only Plan", undoManager: f.undo))
        #expect(e.commandState.isReadOnly)
    }

    @Test func noticeShowsHidesAndUnlocks() {
        let f = LockFixture()
        let e = f.editor
        #expect(e.readOnlyNotice == nil)
        e.select(f.beta)
        e.perform(.delete)
        let first = e.readOnlyNotice
        #expect(first != nil)
        e.perform(.addChild) // re-armed, same notice
        #expect(e.readOnlyNotice?.id == first?.id && e.readOnlyNotice?.token != first?.token)
        f.flush() // first timer: superseded, keeps it; second hides it
        #expect(e.readOnlyNotice == nil)
        e.perform(.edit)
        #expect(e.readOnlyNotice != nil)
        e.unlockFromNotice()
        #expect(!e.isReadOnly && e.readOnlyNotice == nil)
        #expect(f.undo.undoActionName == "Unlock Editing")
        // Unlocked: edits work again.
        e.select(f.beta)
        e.perform(.addChild)
        #expect(e.editingID != nil)
    }

    @Test func toggleCommandShortcutAndCommandState() {
        let f = LockFixture(locked: false)
        #expect(KeyCommandMap.command(key: KeyEquivalent("l"), modifiers: [.command, .option], characters: "l")
            == .toggleReadOnly)
        #expect(KeyCommandMap.command(key: KeyEquivalent("l"), modifiers: .command, characters: "l") == .addRelationship)
        #expect(!f.editor.commandState.isReadOnly)
        f.editor.perform(.toggleReadOnly)
        #expect(f.editor.isReadOnly && f.editor.commandState.isReadOnly)
        f.editor.perform(.toggleReadOnly)
        #expect(!f.editor.isReadOnly)
    }

    @Test func lockingCommitsTheRenameInProgressAndEndsInteractions() {
        let f = LockFixture(locked: false)
        let e = f.editor
        e.beginEditing(f.beta)
        e.draftText = "Beta renamed"
        e.beginRelationship(from: f.gamma) // commits the rename, enters pick mode
        e.setReadOnly(true)
        #expect(e.model.map.node(withID: f.beta)?.text == "Beta renamed")
        #expect(e.editingID == nil && e.pickMode == nil)
        #expect(f.undo.undoActionName == "Lock Editing")
    }
}

/// Persistence, sync and undo of the lock itself.
@MainActor
@Suite struct ReadOnlyPersistenceTests {
    @Test func jsonKeyOnlyWhenLockedAndOlderFilesOpenUnlocked() throws {
        var map = MindMap(root: Node(text: "Plan"))
        let plain = String(decoding: try MindMapPackage.encode(map), as: UTF8.self)
        #expect(!plain.contains("isReadOnly"))
        map.isReadOnly = true
        let locked = String(decoding: try MindMapPackage.encode(map), as: UTF8.self)
        #expect(locked.contains("\"isReadOnly\" : true"))
        #expect(try MindMapPackage.decode(Data(locked.utf8)).isReadOnly)
        let explicitFalse = locked.replacingOccurrences(of: "\"isReadOnly\" : true", with: "\"isReadOnly\" : false")
        let decoded = try MindMapPackage.decode(Data(explicitFalse.utf8))
        #expect(!decoded.isReadOnly)
        #expect(!String(decoding: try MindMapPackage.encode(decoded), as: UTF8.self).contains("isReadOnly"))
        let garbage = locked.replacingOccurrences(of: "\"isReadOnly\" : true", with: "\"isReadOnly\" : \"yes\"")
        #expect(!(try MindMapPackage.decode(Data(garbage.utf8)).isReadOnly))
        // Through a package on disk, as a document saves / opens it.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReadOnly-\(UUID()).mindmap")
        try MindMapPackage.fileWrapper(for: map).write(to: url, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = MindMapModel()
        try model.load(package: FileWrapper(url: url, options: .immediate))
        #expect(model.isReadOnly)
        #expect(EditorController(model: model).isReadOnly)
    }

    @Test func toggleIsOneUndoStepThatDirtiesTheDocument() {
        let f = LockFixture(locked: false)
        f.editor.setReadOnly(true)
        #expect(f.undo.canUndo && f.undo.undoActionName == "Lock Editing") // registered = document dirty
        #expect(!f.undo.canRedo)
        f.undo.undo()
        #expect(!f.model.isReadOnly)
        f.undo.redo()
        #expect(f.model.isReadOnly)
        f.editor.setReadOnly(true) // already on: no step
        #expect(f.undo.undoActionName == "Lock Editing")
    }

    @Test func undoWhileLockedNeverChangesContent() {
        let f = LockFixture(locked: false)
        let e = f.editor
        e.select(f.beta)
        e.perform(.addChild)
        e.commitEditing()
        e.toggleTaskDone(f.gamma)
        let edited = f.content
        e.setReadOnly(true)
        e.toggleCollapse(f.alpha) // unfold while locked
        e.collapseToLevel(1)
        f.undo.undo() // Collapse to Level
        f.undo.undo() // Expand
        #expect(f.model.isReadOnly, "undo: \(f.undo.undoActionName)")
        #expect(f.content == edited, "\(f.content.root) vs \(edited.root)")
        #expect(f.model.map.node(withID: f.alpha)?.isCollapsed == true)
        f.undo.undo() // Lock Editing -> unlocked, content still the edited one
        #expect(!f.model.isReadOnly && f.content == edited)
        f.undo.undo() // now content steps undo again
        #expect(f.model.map.task(of: f.gamma)?.isDone == false)
    }

    @Test func lockSyncsThroughTheLibraryAndMerges() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let db = MockCloudDatabase()
        let a = MockDevice(database: db), b = MockDevice(database: db)
        let summary = try a.store.importMap(MindMap(root: Node(text: "Plan", children: [Node(text: "X"), Node(text: "Y")])))
        let id = try a.libraryID(summary)
        try await a.syncNow()
        try await b.syncNow()
        #expect(try !b.map(id).isReadOnly)

        // Device A locks it; device B renames a topic meanwhile.
        var onA = try a.map(id)
        onA.isReadOnly = true
        try a.save(onA, id: id, modified: t0)
        var onB = try b.map(id)
        onB.root.children[0].text = "X from B"
        try b.save(onB, id: id, modified: t0.addingTimeInterval(10))
        try await a.syncNow()
        try await b.syncNow() // conflict -> per-field merge
        try await a.syncNow()
        for device in [a, b] {
            let merged = try device.map(id)
            #expect(merged.isReadOnly)
            #expect(merged.root.children.map(\.text) == ["X from B", "Y"])
        }
        // Unlocked on B: A follows.
        var unlocked = try b.map(id)
        unlocked.isReadOnly = false
        try b.save(unlocked, id: id, modified: t0.addingTimeInterval(20))
        try await b.syncNow()
        try await a.syncNow()
        #expect(try !a.map(id).isReadOnly)
        // Merge of the field alone (pure).
        let base = MindMap(root: Node(text: "R"))
        var local = base
        local.isReadOnly = true
        #expect(MapMerge.merge(base: base, local: .init(map: local, modified: t0),
                               remote: .init(map: base, modified: t0.addingTimeInterval(5))).map.isReadOnly)
    }
}

/// ⌘Z / ⇧⌘Z of an expand / collapse keep the toggled topic still on screen
/// (WP17 leftover), also when the undo bypasses the editor (system Edit menu).
@MainActor
@Suite struct UndoAnchoringTests {
    private func makeEditor() -> (EditorController, UndoManager, UUID, UUID, UUID) {
        let big = Node(text: "Big branch", children: (0..<8).map { Node(text: "Child \($0)") })
        let other = Node(text: "Other", children: (0..<3).map { Node(text: "O\($0)") })
        let bottom = Node(text: "Bottom")
        let root = Node(text: "Central", layoutStyle: .rightMap, children: [Node(text: "Top"), big, other, bottom])
        let editor = EditorController(model: MindMapModel(map: MindMap(root: root)))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.updateViewSize(CGSize(width: 1200, height: 900))
        return (editor, undo, big.id, other.id, bottom.id)
    }

    private func screenMid(_ editor: EditorController, _ id: UUID) -> CGPoint {
        let frame = editor.viewport.toScreen(editor.scene.layout.frames[id]!)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    @Test(arguments: [false, true]) func undoAndRedoOfAToggleStayAnchored(locked: Bool) {
        let (editor, undo, big, other, bottom) = makeEditor()
        if locked { editor.setReadOnly(true) }
        let start = screenMid(editor, big), bottomStart = screenMid(editor, bottom)
        editor.toggleCollapse(big)
        #expect(distance(screenMid(editor, big), start) < 1) // forward (WP17)
        #expect(distance(screenMid(editor, bottom), bottomStart) > 20) // the rest of the map did move
        editor.select(other) // the selection moved elsewhere meanwhile
        undo.undo() // bypassing the editor, like Edit ▸ Undo
        #expect(editor.model.map.node(withID: big)?.isCollapsed == false)
        #expect(distance(screenMid(editor, big), start) < 1)
        undo.redo()
        #expect(editor.model.map.node(withID: big)?.isCollapsed == true)
        #expect(distance(screenMid(editor, big), start) < 1)
        editor.undo() // the editor's own Undo (toolbar, iPad ⌘Z)
        #expect(distance(screenMid(editor, big), start) < 1)
    }

    @Test func undoOfLevelsAndBranchesStayAnchored() {
        let (editor, undo, big, _, _) = makeEditor()
        editor.select(big)
        let start = screenMid(editor, big)
        editor.collapseToLevel(1)
        undo.undo()
        #expect(distance(screenMid(editor, big), start) < 1)
        editor.collapseBranch(big)
        let folded = screenMid(editor, big)
        undo.undo()
        #expect(distance(screenMid(editor, big), folded) < 1)
        // Non-fold steps replay as before (no anchoring involved).
        editor.addChild()
        editor.commitEditing()
        undo.undo()
        #expect(editor.model.map.node(withID: big)?.children.count == 8)
        #expect(MapEdit.collapseTargets(of: [.tree(.rename(id: big, text: "x"))]).isEmpty)
        #expect(MapEdit.collapseTargets(of: [.tree(.setCollapsed(id: big, true)), .tree(.set(id: big, .side(.left)))])
            == [big])
    }
}
