import CoreGraphics
import Foundation
import Testing
@testable import MindMap

/// WP11 iPad touch + Apple Pencil UX: the pure state machine / geometry /
/// policies and the editor routing they drive (platform independent; the
/// UIKit Pencil bridge itself cannot be driven in the simulator).
private struct TouchFixture {
    let research = UUID(), survey = UUID(), design = UUID(), launch = UUID()
    let rootID = UUID()

    var map: MindMap {
        MindMap(root: Node(id: rootID, text: "Central", layoutStyle: .rightMap, children: [
            Node(id: research, text: "Research", children: [Node(id: survey, text: "Survey")]),
            Node(id: design, text: "Design"),
            Node(id: launch, text: "Launch"),
        ]))
    }

    /// Editor whose deferred palette shows run when `flush()` is called.
    final class Deferred {
        var work: [() -> Void] = []
        func flush() {
            let pending = work
            work = []
            pending.forEach { $0() }
        }
    }

    func editor() -> (EditorController, UndoManager, Deferred) {
        let editor = EditorController(model: MindMapModel(map: map))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        let deferred = Deferred()
        editor.paletteScheduler = { _, work in deferred.work.append(work) }
        editor.updateViewSize(CGSize(width: 1000, height: 800))
        return (editor, undo, deferred)
    }

    func center(_ id: UUID, in editor: EditorController) -> CGPoint {
        let frame = editor.screenFrame(of: id)!
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

private func expectSingleUndo(_ undo: UndoManager, _ model: MindMapModel, restores before: MindMap) {
    #expect(undo.canUndo)
    undo.undo()
    #expect(model.map == before)
    #expect(!undo.canUndo)
}

// MARK: - Palette visibility state machine

struct PaletteStateTests {
    @Test func scheduledShowWaitsForItsToken() {
        var state = ActionPaletteState()
        let first = state.schedule()
        #expect(state.visibleMode(hasSelection: true, isBusy: false) == nil)
        let second = state.schedule()
        state.fire(first) // stale (a newer tap replaced it)
        #expect(state.visibleMode(hasSelection: true, isBusy: false) == nil)
        state.fire(second)
        #expect(state.visibleMode(hasSelection: true, isBusy: false) == .selection)
        state.dismiss()
        #expect(state.visibleMode(hasSelection: true, isBusy: false) == nil)
        // Dismiss cancels a pending show too.
        let third = state.schedule()
        state.dismiss()
        state.fire(third)
        #expect(!state.isRequested)
    }

    @Test func gesturesHideUntilAllEnd() {
        var state = ActionPaletteState()
        state.showForSelection()
        state.begin(.pan)
        state.begin(.zoom)
        #expect(state.visibleMode(hasSelection: true, isBusy: false) == nil)
        state.end(.pan)
        #expect(state.visibleMode(hasSelection: true, isBusy: false) == nil)
        state.end(.zoom)
        #expect(state.visibleMode(hasSelection: true, isBusy: false) == .selection)
        #expect(state.visibleMode(hasSelection: true, isBusy: true) == nil)
        #expect(state.visibleMode(hasSelection: false, isBusy: false) == nil)
    }

    @Test func insertPaletteSurvivesDeselection() {
        var state = ActionPaletteState()
        state.showInsert(at: CGPoint(x: 10, y: 20))
        state.selectionCleared()
        #expect(state.visibleMode(hasSelection: false, isBusy: false) == .insert(CGPoint(x: 10, y: 20)))
        state.showForSelection()
        state.selectionCleared()
        #expect(!state.isRequested)
    }

    @Test func tapShowsPaletteAfterIntervalAndBackgroundTapHides() {
        let f = TouchFixture()
        let (editor, _, deferred) = f.editor()
        #expect(editor.touchTapTopic(f.design, at: f.center(f.design, in: editor), time: 10) == .selected)
        #expect(editor.selectedIDs == [f.design])
        #expect(editor.visiblePalette == nil) // not before the double-tap interval
        deferred.flush()
        #expect(editor.visiblePalette == .selection)
        #expect(editor.paletteItems.map(\.action) == [.addChild, .addSibling, .rename, .delete, .note, .link,
                                                        .task, .more])
        // Tap on empty canvas: the canvas calls these two.
        editor.touchTapBackground()
        editor.select(nil)
        #expect(editor.visiblePalette == nil && editor.selectedID == nil)
    }

    @Test func tapOnTopicWithPaletteHidesIt() {
        let f = TouchFixture()
        let (editor, _, deferred) = f.editor()
        let point = f.center(f.design, in: editor)
        editor.touchTapTopic(f.design, at: point, time: 10)
        deferred.flush()
        #expect(editor.touchTapTopic(f.design, at: point, time: 20) == .hidPalette)
        #expect(editor.visiblePalette == nil && editor.selectedID == f.design)
        // Tapping another topic moves selection; palette follows after the interval.
        #expect(editor.touchTapTopic(f.launch, at: f.center(f.launch, in: editor), time: 30) == .selected)
        deferred.flush()
        #expect(editor.visiblePalette == .selection && editor.selectedID == f.launch)
    }

    @Test func dragPanZoomAndEditingHideThenRestore() throws {
        let f = TouchFixture()
        let (editor, _, deferred) = f.editor()
        editor.touchTapTopic(f.design, at: f.center(f.design, in: editor), time: 10)
        deferred.flush()
        // Drag (topic follows the finger): hidden, back after the drop.
        editor.updateDrag(f.design, translation: CGSize(width: 0, height: 3), location: .zero)
        #expect(editor.visiblePalette == nil)
        editor.drag = nil
        #expect(editor.visiblePalette == .selection)
        editor.beginCanvasGesture(.pan)
        #expect(editor.visiblePalette == nil)
        editor.endCanvasGesture(.pan)
        editor.beginCanvasGesture(.zoom)
        #expect(editor.visiblePalette == nil)
        editor.endCanvasGesture(.zoom)
        #expect(editor.visiblePalette == .selection)
        // Editing (Child) hides it; it returns on the new topic after commit.
        editor.performPaletteAction(.addChild)
        let child = try #require(editor.editingID)
        #expect(editor.visiblePalette == nil)
        editor.commitEditing()
        #expect(editor.selectedID == child && editor.visiblePalette == .selection)
        // Hardware keyboard: palette goes away.
        editor.keyboardDidAct()
        #expect(editor.visiblePalette == nil)
    }

    @Test func multiSelectionPaletteAndSelectMode() {
        let f = TouchFixture()
        let (editor, _, deferred) = f.editor()
        editor.isSelectMode = true
        #expect(editor.touchTapTopic(f.research, at: f.center(f.research, in: editor), time: 1) == .toggled)
        #expect(editor.touchTapTopic(f.launch, at: f.center(f.launch, in: editor), time: 1.1) == .toggled)
        deferred.flush()
        #expect(editor.selectedIDs == [f.research, f.launch])
        #expect(editor.visiblePalette == .selection)
        // Valid for many: Task, Boundary, Collapse (Research has children), Delete, More.
        #expect(editor.paletteItems.map(\.action) == [.task, .boundary, .collapse, .delete, .more])
        // Marquee hides it while drawing.
        editor.updateMarquee(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1, y: 1))
        #expect(editor.visiblePalette == nil)
        editor.endMarquee()
        editor.touchMarqueeEnded()
        #expect(editor.visiblePalette == .selection)
    }

    @Test func longPressHidesPaletteForContextMenu() {
        let f = TouchFixture()
        let (editor, _, deferred) = f.editor()
        editor.touchTapTopic(f.design, at: f.center(f.design, in: editor), time: 1)
        deferred.flush()
        editor.touchLongPress(f.launch)
        #expect(editor.visiblePalette == nil && editor.selectedID == f.launch)
    }
}

// MARK: - Tap vs double-tap

struct TapDisambiguationTests {
    @Test func sequenceRules() {
        var taps = TapSequence()
        let a = UUID(), b = UUID()
        #expect(taps.classify(target: a, location: .zero, time: 1) == .single)
        #expect(taps.classify(target: a, location: CGPoint(x: 5, y: 5), time: 1.2) == .double)
        // Third tap starts a new sequence.
        #expect(taps.classify(target: a, location: .zero, time: 1.3) == .single)
        // Too slow.
        #expect(taps.classify(target: a, location: .zero, time: 1.3 + TapSequence.maxInterval + 0.01) == .single)
        // Another topic.
        #expect(taps.classify(target: b, location: .zero, time: 1.7) == .single)
        // Too far apart.
        #expect(taps.classify(target: b, location: CGPoint(x: 40, y: 0), time: 1.8) == .single)
        taps.reset()
        #expect(taps.classify(target: b, location: CGPoint(x: 40, y: 0), time: 1.85) == .single)
    }

    @Test func doubleTapRenamesWithoutFlashingPalette() {
        let f = TouchFixture()
        let (editor, undo, deferred) = f.editor()
        let point = f.center(f.design, in: editor)
        #expect(editor.touchTapTopic(f.design, at: point, time: 5) == .selected)
        #expect(editor.touchTapTopic(f.design, at: point, time: 5.2) == .rename)
        #expect(editor.editingID == f.design && editor.draftText == "Design" && editor.editSelectsAll)
        deferred.flush() // the first tap's deferred show is stale now
        #expect(editor.visiblePalette == nil)
        // A tap on the edited topic belongs to the text field.
        #expect(editor.touchTapTopic(f.design, at: point, time: 6) == .ignored)
        editor.draftText = "Design 2"
        editor.commitEditing()
        #expect(editor.model.map.node(withID: f.design)?.text == "Design 2")
        #expect(editor.model.root.children.count == 3) // iPad double-tap never adds a child
        undo.undo()
        #expect(editor.model.map.node(withID: f.design)?.text == "Design")
    }

    @Test func checkboxDoubleTapIsNotRename() {
        let f = TouchFixture()
        let (editor, _, _) = f.editor()
        let point = f.center(f.design, in: editor)
        editor.touchTapTopic(f.design, at: point, time: 5)
        editor.lastCheckboxClick = (f.design, Date())
        #expect(editor.touchTapTopic(f.design, at: point, time: 5.1) == .selected)
        #expect(editor.editingID == nil)
    }

    @Test func tapsCompletePicks() {
        let f = TouchFixture()
        let (editor, _, _) = f.editor()
        editor.beginRelationship(from: f.design)
        #expect(editor.touchTapTopic(f.launch, at: f.center(f.launch, in: editor), time: 1) == .picked)
        #expect(editor.model.map.relationships.count == 1)
    }
}

// MARK: - Palette action routing (one undo step each)

struct PaletteActionRoutingTests {
    @Test func childSiblingRenameDelete() throws {
        let f = TouchFixture()
        let (editor, undo, _) = f.editor()
        let before = editor.model.map
        editor.select(f.design)
        editor.performPaletteAction(.addChild)
        let child = try #require(editor.editingID)
        editor.draftText = "Idea"
        editor.commitEditing()
        #expect(editor.model.map.parentID(of: child) == f.design)
        expectSingleUndo(undo, editor.model, restores: before) // add + naming = one step

        editor.select(f.design)
        editor.performPaletteAction(.addSibling)
        let sibling = try #require(editor.editingID)
        editor.commitEditing()
        #expect(editor.model.map.parentID(of: sibling) == f.rootID)
        expectSingleUndo(undo, editor.model, restores: before)

        editor.select(f.launch)
        editor.performPaletteAction(.rename)
        #expect(editor.editingID == f.launch)
        editor.draftText = "Go live"
        editor.commitEditing()
        #expect(editor.model.map.node(withID: f.launch)?.text == "Go live")
        expectSingleUndo(undo, editor.model, restores: before)

        editor.select(f.launch)
        editor.palette.showForSelection()
        editor.performPaletteAction(.delete)
        #expect(!editor.model.map.contains(f.launch))
        #expect(editor.visiblePalette == nil)
        expectSingleUndo(undo, editor.model, restores: before)
    }

    @Test func taskToggleAndMultiTask() {
        let f = TouchFixture()
        let (editor, undo, _) = f.editor()
        let before = editor.model.map
        editor.select(f.design)
        editor.performPaletteAction(.task)
        #expect(editor.task(of: f.design)?.isDone == false)
        #expect(editor.paletteContext.isTask)
        editor.performPaletteAction(.task)
        #expect(editor.task(of: f.design)?.isDone == true)
        undo.undo()
        expectSingleUndo(undo, editor.model, restores: before)

        editor.setSelection([f.design, f.launch], primary: f.launch)
        editor.performPaletteAction(.task)
        #expect(editor.task(of: f.design) != nil && editor.task(of: f.launch) != nil)
        editor.performPaletteAction(.task) // all tasks now: Done for all
        #expect(editor.task(of: f.design)?.isDone == true && editor.task(of: f.launch)?.isDone == true)
        undo.undo()
        expectSingleUndo(undo, editor.model, restores: before)
    }

    @Test func boundaryCollapseOnSelection() {
        let f = TouchFixture()
        let (editor, undo, _) = f.editor()
        let before = editor.model.map
        editor.setSelection([f.research, f.design], primary: f.design)
        editor.performPaletteAction(.boundary)
        #expect(editor.model.map.boundaries.first?.memberIDs == [f.research, f.design])
        expectSingleUndo(undo, editor.model, restores: before)

        editor.setSelection([f.research, f.design], primary: f.research)
        editor.performPaletteAction(.collapse)
        #expect(editor.model.map.node(withID: f.research)?.isCollapsed == true)
        expectSingleUndo(undo, editor.model, restores: before)
    }

    @Test func noteLinkDrawingFileRelationshipOpenTheirUI() {
        let f = TouchFixture()
        let (editor, undo, _) = f.editor()
        let before = editor.model.map
        editor.select(f.design)
        editor.performPaletteAction(.note)
        // A new note is an empty draft (joins the map with its first text).
        let note = editor.presentedAttachment?.attachmentID
        #expect(note.map { editor.model.attachment($0)?.kind == .markdown && editor.model.isDraft($0) } == true)
        #expect(!undo.canUndo && editor.model.map == before)
        note.map { _ = editor.model.discardIfEmpty($0, undoManager: undo) }
        editor.presentedAttachment = nil

        editor.select(f.design)
        editor.performPaletteAction(.link)
        #expect(editor.linkEditor?.nodeID == f.design)
        editor.linkEditor = nil

        editor.select(f.design)
        editor.performPaletteAction(.drawing)
        let drawing = editor.presentedAttachment?.attachmentID
        #expect(drawing.map { editor.model.attachment($0)?.kind == .drawing && editor.model.isDraft($0) } == true)
        #expect(!undo.canUndo && editor.model.map == before)
        drawing.map { _ = editor.model.discardIfEmpty($0, undoManager: undo) }
        editor.presentedAttachment = nil

        editor.select(f.design)
        editor.performPaletteAction(.attachFile)
        #expect(editor.isFileImporterPresented && editor.fileImportTarget == f.design)

        editor.select(f.design)
        editor.performPaletteAction(.relationship)
        #expect(editor.pickMode == .relationship(from: f.design))
    }

    @Test func insertPaletteFloatingTopicAtPoint() throws {
        let f = TouchFixture()
        let (editor, undo, _) = f.editor()
        let before = editor.model.map
        let point = CGPoint(x: 900, y: 700)
        editor.palette.showInsert(at: point)
        #expect(editor.paletteItems.map(\.action) == [.floatingTopic])
        editor.performPaletteAction(.floatingTopic)
        let id = try #require(editor.editingID)
        let frame = try #require(editor.screenFrame(of: id))
        #expect(abs(frame.midX - point.x) < 1 && abs(frame.midY - point.y) < 1)
        #expect(editor.palette.mode == nil)
        editor.commitEditing()
        expectSingleUndo(undo, editor.model, restores: before)
    }

    @Test func catalogRules() {
        let root = ActionPaletteCatalog.items(for: PaletteContext(count: 1, isMainRoot: true, isTreeRoot: true))
        #expect(!root.contains { $0.action == .delete })
        #expect(root.first { $0.action == .addSibling }?.isEnabled == false)
        let done = ActionPaletteCatalog.items(for: PaletteContext(count: 1, isTask: true, isDoneTask: true))
        #expect(done.first { $0.action == .task }?.title == "Reopen")
        let many = ActionPaletteCatalog.items(for: PaletteContext(count: 3, hasChildren: false, allTasks: true,
                                                                  hasMovable: false))
        #expect(many.map(\.action) == [.task, .boundary, .delete, .more])
        #expect(many.first { $0.action == .task }?.title == "Done")
        #expect(many.first { $0.action == .delete }?.isEnabled == false)
        #expect(ActionPaletteCatalog.items(for: PaletteContext(count: 0)).isEmpty)
        #expect(ActionPaletteCatalog.insertItems(hasSelection: true).map(\.action)
            == [.floatingTopic, .addChild, .note, .drawing, .attachFile, .relationship])
    }
}

// MARK: - Placement

struct PalettePlacementTests {
    let container = CGSize(width: 800, height: 600)
    let size = CGSize(width: 400, height: 54)

    @Test func aboveByDefaultBelowWhenNoRoom() throws {
        let anchor = CGRect(x: 300, y: 300, width: 100, height: 40)
        let above = try #require(PalettePlacement.place(anchor: anchor, size: size, in: container))
        #expect(above.isAbove && above.center.y == 300 - 10 - 27 && above.center.x == 350)
        let top = CGRect(x: 300, y: 20, width: 100, height: 40)
        let below = try #require(PalettePlacement.place(anchor: top, size: size, in: container, belowClearance: 30))
        #expect(!below.isAbove && below.center.y == 60 + 10 + 30 + 27)
    }

    @Test func clampedToEdgesAndHiddenOffscreen() throws {
        let left = CGRect(x: -40, y: 300, width: 100, height: 40)
        let result = try #require(PalettePlacement.place(anchor: left, size: size, in: container))
        #expect(abs(result.center.x - 212) < 0.001, "\(result.center.x)")
        let right = CGRect(x: 760, y: 300, width: 100, height: 40)
        let clampedRight = try #require(PalettePlacement.place(anchor: right, size: size, in: container))
        #expect(abs(clampedRight.center.x - 588) < 0.001, "\(clampedRight.center.x)")
        #expect(PalettePlacement.place(anchor: CGRect(x: 900, y: 300, width: 50, height: 20), size: size,
                                       in: container) == nil)
        // Banner inset pushes it below.
        let nearTop = CGRect(x: 300, y: 90, width: 100, height: 40)
        #expect(PalettePlacement.place(anchor: nearTop, size: size, in: container, topInset: 52)?.isAbove == false)
    }

    @Test func obstaclesPreferTheFreeSide() throws {
        let anchor = CGRect(x: 300, y: 300, width: 100, height: 40)
        let obstacle = CGRect(x: 250, y: 240, width: 200, height: 40) // right above
        let result = try #require(PalettePlacement.place(anchor: anchor, size: size, in: container,
                                                         obstacles: [obstacle]))
        #expect(!result.isAbove)
        // Both sides blocked equally: above wins.
        let both = [obstacle, CGRect(x: 250, y: 355, width: 200, height: 40)]
        #expect(PalettePlacement.place(anchor: anchor, size: size, in: container, obstacles: both)?.isAbove == true)
    }

    @Test func multiSelectionAnchor() {
        let a = CGRect(x: 100, y: 100, width: 50, height: 20), b = CGRect(x: 300, y: 160, width: 50, height: 20)
        #expect(PalettePlacement.anchor(primary: b, selection: [a, b], container: container) == a.union(b))
        let far = CGRect(x: 300, y: 560, width: 50, height: 20)
        #expect(PalettePlacement.anchor(primary: far, selection: [a, far], container: container) == far)
    }
}

// MARK: - "+" handle

struct AddChildHandleTests {
    let frame = CGRect(x: 100, y: 100, width: 80, height: 30)

    @Test func centerPerEdgeBeyondToggle() {
        let offset = AddChildHandle.gap + AddChildHandle.diameter / 2
        #expect(AddChildHandle.center(frame: frame, edge: .trailing, toggleExtent: 0) == CGPoint(x: 180 + offset, y: 115))
        #expect(AddChildHandle.center(frame: frame, edge: .leading, toggleExtent: 20) == CGPoint(x: 100 - 20 - offset, y: 115))
        #expect(AddChildHandle.center(frame: frame, edge: .bottom, toggleExtent: 0) == CGPoint(x: 140, y: 130 + offset))
        #expect(AddChildHandle.toggleExtent(isShown: false, edge: .trailing, isCollapsed: false, hiddenCount: 0, scale: 1) == 0)
        let minus = AddChildHandle.toggleExtent(isShown: true, edge: .trailing, isCollapsed: false, hiddenCount: 0, scale: 1)
        let plusMany = AddChildHandle.toggleExtent(isShown: true, edge: .trailing, isCollapsed: true, hiddenCount: 128,
                                                   scale: 1)
        #expect(minus == 4 + 16 + 3 && plusMany > minus)
    }

    @Test func hitTesting() {
        let center = AddChildHandle.center(frame: frame, edge: .trailing, toggleExtent: 0)
        // The touch target touches the topic edge but never reaches into it.
        #expect(abs(center.x - AddChildHandle.hitDiameter / 2 - frame.maxX) < 0.001)
        #expect(AddChildHandle.contains(CGPoint(x: center.x + 21, y: center.y), center: center))
        #expect(!AddChildHandle.contains(CGPoint(x: center.x + 23, y: center.y), center: center))
        let id = UUID(), other = UUID()
        let otherCenter = CGPoint(x: center.x + 30, y: center.y)
        #expect(AddChildHandle.target(at: CGPoint(x: center.x + 5, y: center.y),
                                      handles: [id: center, other: otherCenter]) == id)
        #expect(AddChildHandle.target(at: CGPoint(x: center.x + 25, y: center.y),
                                      handles: [id: center, other: otherCenter]) == other)
        // A point on a topic is the topic's, not a handle's.
        #expect(AddChildHandle.target(at: CGPoint(x: frame.maxX - 1, y: frame.midY), handles: [id: center],
                                      topicFrames: [UUID(): frame]) == nil)
    }

    @Test func visibilityRules() {
        let a = UUID(), b = UUID()
        #expect(AddChildHandle.isShown(for: a, selection: [a], hoveredID: nil, editingID: nil, isBusy: false))
        #expect(!AddChildHandle.isShown(for: a, selection: [a, b], hoveredID: nil, editingID: nil, isBusy: false))
        #expect(AddChildHandle.isShown(for: b, selection: [a], hoveredID: b, editingID: nil, isBusy: false))
        #expect(!AddChildHandle.isShown(for: a, selection: [a], hoveredID: nil, editingID: a, isBusy: false))
        #expect(!AddChildHandle.isShown(for: a, selection: [a], hoveredID: nil, editingID: nil, isBusy: true))
    }

    @Test func editorHandleAddsChildInEditing() throws {
        let f = TouchFixture()
        let (editor, undo, _) = f.editor()
        let before = editor.model.map
        editor.select(f.design)
        #expect(editor.showsAddChildHandle(f.design))
        #expect(!editor.showsAddChildHandle(f.launch))
        let center = try #require(editor.addChildHandleCenter(for: f.design))
        let frame = try #require(editor.screenFrame(of: f.design))
        #expect(center.x > frame.maxX && abs(center.y - frame.midY) < 0.001)
        // Research has children and is selected: its handle sits beyond the "−" toggle.
        editor.select(f.research)
        let research = try #require(editor.screenFrame(of: f.research))
        let handle = try #require(editor.addChildHandleCenter(for: f.research))
        #expect(handle.x - research.maxX > AddChildHandle.gap + AddChildHandle.diameter / 2 + 16)
        editor.isSelectMode = true
        #expect(!editor.showsAddChildHandle(f.research))
        editor.isSelectMode = false

        editor.tapAddChildHandle(f.launch)
        let child = try #require(editor.editingID)
        #expect(editor.model.map.parentID(of: child) == f.launch && editor.editSelectsAll)
        #expect(!editor.showsAddChildHandle(child)) // hidden while naming
        editor.commitEditing()
        expectSingleUndo(undo, editor.model, restores: before)
    }
}

// MARK: - Apple Pencil (decisions; real Pencil events cannot be simulated)

struct PencilPolicyTests {
    let selected = UUID()
    let point = CGPoint(x: 5, y: 5)

    @Test func doubleTapHonorsPreference() {
        func action(_ preference: PencilPreference, _ id: UUID?, multi: Bool = false) -> PencilMapAction? {
            PencilPolicy.doubleTapAction(preference: preference, selectedID: id, isMultiSelection: multi,
                                         fallbackPoint: point)
        }
        #expect(action(.ignore, selected) == nil)
        #expect(action(.runSystemShortcut, selected) == nil)
        for tool in [PencilPreference.switchEraser, .switchPrevious, .showColorPalette, .showInkAttributes, .other] {
            #expect(action(tool, selected) == .addChild(selected))
            #expect(action(tool, nil) == nil)
        }
        #expect(action(.switchEraser, selected, multi: true) == .showPalette)
        #expect(action(.showContextualPalette, selected) == .showPalette)
        #expect(action(.showContextualPalette, nil) == .insertMenu(point))
    }

    @Test func squeezeTargets() {
        let topic = UUID()
        func action(_ preference: PencilPreference = .showContextualPalette, hover: CGPoint?, topic: UUID?,
                    selected: UUID?, last: CGPoint? = nil) -> PencilMapAction? {
            PencilPolicy.squeezeAction(preference: preference, hoverPoint: hover, topicAtHover: topic,
                                       selectedID: selected, lastPoint: last, viewCenter: CGPoint(x: 50, y: 50))
        }
        #expect(action(.ignore, hover: point, topic: topic, selected: selected) == nil)
        #expect(action(.runSystemShortcut, hover: nil, topic: nil, selected: selected) == nil)
        #expect(action(hover: point, topic: topic, selected: selected) == .selectAndShowPalette(topic))
        #expect(action(hover: point, topic: nil, selected: selected) == .insertMenu(point))
        #expect(action(.switchEraser, hover: nil, topic: nil, selected: selected) == .showPalette)
        #expect(action(hover: nil, topic: nil, selected: nil, last: point) == .insertMenu(point))
        #expect(action(hover: nil, topic: nil, selected: nil) == .insertMenu(CGPoint(x: 50, y: 50)))
    }

    @Test func editorPencilRouting() throws {
        let f = TouchFixture()
        let (editor, undo, _) = f.editor()
        let before = editor.model.map
        editor.select(f.design)
        #expect(editor.pencilDoubleTap(preference: .switchEraser) == .addChild(f.design))
        let child = try #require(editor.editingID)
        #expect(editor.model.map.parentID(of: child) == f.design)
        editor.commitEditing()
        expectSingleUndo(undo, editor.model, restores: before)
        #expect(editor.pencilDoubleTap(preference: .ignore) == nil)

        // Squeeze over a topic selects it + palette; squeezing again hides it.
        editor.select(f.design)
        let launch = f.center(f.launch, in: editor)
        #expect(editor.pencilSqueeze(preference: .showContextualPalette, hoverPoint: launch)
            == .selectAndShowPalette(f.launch))
        #expect(editor.selectedID == f.launch && editor.visiblePalette == .selection)
        editor.pencilSqueeze(preference: .showContextualPalette, hoverPoint: launch)
        #expect(editor.visiblePalette == nil)
        // Over empty canvas: Insert palette there.
        let empty = CGPoint(x: 990, y: 790)
        #expect(editor.pencilSqueeze(preference: .showContextualPalette, hoverPoint: empty) == .insertMenu(empty))
        #expect(editor.visiblePalette == .insert(empty))
    }

    @Test func hoverHighlightKeepsTopicOverItsHandle() throws {
        let f = TouchFixture()
        let (editor, _, _) = f.editor()
        editor.pencilHover(at: f.center(f.launch, in: editor))
        #expect(editor.pencilHoveredID == f.launch && editor.isHoverHighlighted(f.launch))
        #expect(editor.showsAddChildHandle(f.launch))
        let handle = try #require(editor.addChildHandleCenter(for: f.launch))
        editor.pencilHover(at: handle)
        #expect(editor.pencilHoveredID == f.launch)
        editor.pencilHover(at: CGPoint(x: 995, y: 795))
        #expect(editor.pencilHoveredID == nil && editor.lastPencilPoint == CGPoint(x: 995, y: 795))
        editor.pencilHover(at: nil)
        #expect(editor.pencilHoverPoint == nil)
    }

    @Test func scribbleTargetsAndFocus() throws {
        let f = TouchFixture()
        let (editor, _, _) = f.editor()
        let frame = try #require(editor.screenFrame(of: f.launch))
        #expect(editor.scribbleTopics(inScreenRect: frame.insetBy(dx: 10, dy: 5)) == [f.launch])
        #expect(editor.scribbleTopics(inScreenRect: CGRect(x: 990, y: 790, width: 5, height: 5)).isEmpty)
        editor.beginScribble(on: f.launch)
        #expect(editor.editingID == f.launch && editor.editSelectsAll && editor.draftText == "Launch")
        let a = UUID(), b = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 50, height: 50), b: CGRect(x: 20, y: 20, width: 50, height: 50)]
        #expect(ScribbleTargets.topics(in: CGRect(x: 25, y: 25, width: 1, height: 1), frames: frames, order: [a, b])
            == [b, a])
        #expect(ScribbleTargets.topic(at: CGPoint(x: 25, y: 25), frames: frames, order: [a, b]) == b)
    }
}

struct GestureHelpTests {
    @Test func firstLaunchRule() throws {
        let defaults = try #require(UserDefaults(suiteName: "GestureHelpTests-\(UUID().uuidString)"))
        #expect(GestureHelp.shouldShowOnLaunch(defaults: defaults, environment: [:], isTesting: false))
        #expect(!GestureHelp.shouldShowOnLaunch(defaults: defaults, environment: [:], isTesting: true))
        #expect(!GestureHelp.shouldShowOnLaunch(defaults: defaults, environment: ["MINDMAP_DEBUG_NOTE": "icon"],
                                                isTesting: false))
        defaults.set(true, forKey: GestureHelp.shownKey)
        #expect(!GestureHelp.shouldShowOnLaunch(defaults: defaults, environment: [:], isTesting: false))
        let gestures = GestureHelp.sections.flatMap(\.rows).map(\.gesture).joined(separator: " ")
        for word in ["Tap a topic", "Double-tap a topic", "Long-press", "Tap +", "Drag a topic", "Pinch", "Select",
                     "Squeeze", "Double-tap the Pencil", "Write on a topic", "Hover"] {
            #expect(gestures.contains(word))
        }
    }
}
