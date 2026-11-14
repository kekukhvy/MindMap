import CoreGraphics
import Foundation
import SwiftUI
import Testing
#if os(iOS)
import UIKit
#endif
@testable import MindMap

/// WP16 iPad gestures v2: tap = select + fold / unfold (anchored, WP17),
/// double-tap = add a child inside + name it, "+N" / "−" toggle, palette
/// coexistence, Select mode, accessory buttons, Pencil. Platform independent
/// (the editor API the iOS canvas calls; real touches are not simulatable).
private struct FoldFixture {
    let rootID = UUID(), research = UUID(), interviews = UUID(), survey = UUID()
    let design = UUID(), wireframes = UUID(), launch = UUID()

    var map: MindMap {
        MindMap(root: Node(id: rootID, text: "Central", layoutStyle: .rightMap, children: [
            Node(id: research, text: "Research", children: [
                Node(id: interviews, text: "Interviews"), Node(id: survey, text: "Survey"),
            ]),
            Node(id: design, text: "Design", isCollapsed: true, children: [Node(id: wireframes, text: "Wireframes")]),
            Node(id: launch, text: "Launch"),
        ]))
    }

    /// Deferred work (palette shows, tap collapses) runs on `flush()`; the
    /// delays they were scheduled with are recorded.
    final class Deferred {
        var work: [() -> Void] = []
        var delays: [TimeInterval] = []
        var isEmpty: Bool { work.isEmpty }
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
        editor.paletteScheduler = { delay, work in
            deferred.delays.append(delay)
            deferred.work.append(work)
        }
        editor.updateViewSize(CGSize(width: 1000, height: 800))
        return (editor, undo, deferred)
    }

    func center(_ id: UUID, in editor: EditorController) -> CGPoint {
        let frame = editor.screenFrame(of: id)!
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

private func collapsed(_ editor: EditorController, _ id: UUID) -> Bool {
    editor.model.map.node(withID: id)?.isCollapsed == true
}

/// Screen distance the topic moved (anchoring, WP17).
private func moved(_ editor: EditorController, _ id: UUID, from before: CGRect) -> CGFloat {
    guard let after = editor.screenFrame(of: id) else { return .infinity }
    return hypot(after.midX - before.midX, after.midY - before.midY)
}

// MARK: - Pure rules

struct TopicTapPlanTests {
    @Test func planPerTopicState() {
        #expect(TopicTapPlan.plan(hasChildren: false, isCollapsed: false, isMainRoot: false) == .select)
        #expect(TopicTapPlan.plan(hasChildren: true, isCollapsed: true, isMainRoot: false) == .expand)
        #expect(TopicTapPlan.plan(hasChildren: true, isCollapsed: false, isMainRoot: false) == .collapse)
        // The central topic never folds on a tap, but a folded one unfolds.
        #expect(TopicTapPlan.plan(hasChildren: true, isCollapsed: false, isMainRoot: true) == .select)
        #expect(TopicTapPlan.plan(hasChildren: true, isCollapsed: true, isMainRoot: true) == .expand)
        #expect(TopicTapPlan.plan(hasChildren: false, isCollapsed: false, isMainRoot: true) == .select)
    }

    @Test func recentFoldRevertsOnlyWhileLatest() {
        let a = UUID(), b = UUID()
        let map = MindMap()
        let fold = RecentTapFold(id: a, collapsed: true, mapAfter: map)
        #expect(fold.actionName == "Collapse")
        #expect(RecentTapFold(id: a, collapsed: false, mapAfter: map).actionName == "Expand")
        #expect(fold.canRevert(on: a, map: map, canUndo: true, canRedo: false, undoActionName: "Collapse"))
        #expect(!fold.canRevert(on: b, map: map, canUndo: true, canRedo: false, undoActionName: "Collapse"))
        #expect(!fold.canRevert(on: a, map: map, canUndo: false, canRedo: false, undoActionName: "Collapse"))
        #expect(!fold.canRevert(on: a, map: map, canUndo: true, canRedo: true, undoActionName: "Collapse"))
        #expect(!fold.canRevert(on: a, map: map, canUndo: true, canRedo: false, undoActionName: "Add Topic"))
        var changed = map
        changed.root.text = "Other"
        #expect(!fold.canRevert(on: a, map: changed, canUndo: true, canRedo: false, undoActionName: "Collapse"))
    }

    @Test func accessoryWindow() {
        let a = UUID(), b = UUID()
        #expect(!TopicAccessoryTap.isAccessory(nil, id: a, time: 1))
        #expect(TopicAccessoryTap.isAccessory((a, 1), id: a, time: 1.2))
        // The button may run just after the topic's recognizer, too.
        #expect(TopicAccessoryTap.isAccessory((a, 1.1), id: a, time: 1))
        #expect(!TopicAccessoryTap.isAccessory((a, 1), id: b, time: 1.1))
        #expect(!TopicAccessoryTap.isAccessory((a, 1), id: a, time: 1 + TopicAccessoryTap.window + 0.01))
    }

    @Test func doubleTapTiming() {
        var taps = TapSequence()
        let a = UUID()
        #expect(taps.classify(target: a, location: .zero, time: 10) == .single)
        #expect(taps.classify(target: a, location: .zero, time: 10 + TapSequence.maxInterval - 0.001) == .double)
        #expect(taps.classify(target: a, location: .zero, time: 20) == .single)
        #expect(taps.classify(target: a, location: .zero, time: 20 + TapSequence.maxInterval + 0.001) == .single)
        // The palette after an expand waits longer than the relayout.
        #expect(TapSequence.maxInterval > EditorController.relayoutDuration)
    }
}

// MARK: - Single tap folds / unfolds

struct TapFoldTests {
    @Test func tapCollapsesImmediatelyAnchored() {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        let before = editor.model.map
        let frame = editor.screenFrame(of: f.research)!
        #expect(editor.touchTapTopic(f.research, at: f.center(f.research, in: editor), time: 10) == .collapsed)
        // Selected and folded at once (no double-tap wait), one undo step.
        #expect(editor.selectedIDs == [f.research] && collapsed(editor, f.research))
        #expect(moved(editor, f.research, from: frame) < 1)
        #expect(undo.undoActionName == "Collapse")
        // Palette hidden while the fold animates, back after the double-tap
        // interval (longer than the relayout).
        #expect(editor.visiblePalette == nil)
        #expect(deferred.delays == [TapSequence.maxInterval])
        deferred.flush()
        #expect(editor.visiblePalette == .selection && editor.selectedID == f.research)
        undo.undo()
        #expect(editor.model.map == before && !undo.canUndo)
    }

    @Test func collapsingBranchStaysDrawnFadingUntilTheIntervalPasses() {
        let f = FoldFixture()
        let (editor, _, deferred) = f.editor()
        let interviews = editor.screenFrame(of: f.interviews)!
        editor.touchTapTopic(f.research, at: f.center(f.research, in: editor), time: 10)
        // Hidden in the scene, still drawn (fading) where it was on screen.
        #expect(editor.scene.nodes[f.interviews] == nil)
        #expect(editor.drawnOrder.contains(f.interviews) && editor.drawnOrder.contains(f.survey))
        let drawn = editor.drawnNode(f.interviews, in: editor.scene)
        #expect(drawn?.isFading == true)
        if let drawn {
            let screen = editor.viewport.toScreen(drawn.frame)
            #expect(hypot(screen.midX - interviews.midX, screen.midY - interviews.midY) < 1)
        }
        #expect(Set(editor.fadingConnectors.map(\.childID)) == [f.interviews, f.survey])
        #expect(editor.drawnConnectors.filter(\.isFading).count == 2)
        #expect(Set(editor.drawnOrder).count == editor.drawnOrder.count)
        deferred.flush()
        #expect(editor.foldEcho == nil && !editor.drawnOrder.contains(f.interviews))
        #expect(editor.fadingConnectors.isEmpty)
    }

    @Test func tapExpandsCollapsedTopicImmediatelyAnchored() {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        let before = editor.model.map
        let frame = editor.screenFrame(of: f.design)!
        #expect(editor.touchTapTopic(f.design, at: f.center(f.design, in: editor), time: 10) == .expanded)
        #expect(!collapsed(editor, f.design) && editor.selectedID == f.design)
        #expect(editor.scene.nodes[f.wireframes] != nil)
        #expect(moved(editor, f.design, from: frame) < 1)
        // Palette hidden during the expand, shown after the double-tap interval.
        #expect(editor.visiblePalette == nil)
        deferred.flush()
        #expect(editor.visiblePalette == .selection)
        #expect(undo.undoActionName == "Expand")
        undo.undo()
        #expect(editor.model.map == before && !undo.canUndo)
    }

    @Test func secondSingleTapUnfoldsAgain() {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        let point = f.center(f.research, in: editor)
        editor.touchTapTopic(f.research, at: point, time: 10)
        deferred.flush()
        // Slower than the double-tap interval: a new single tap.
        #expect(editor.touchTapTopic(f.research, at: point, time: 10 + TapSequence.maxInterval + 0.05) == .expanded)
        #expect(!collapsed(editor, f.research))
        #expect(editor.model.map.node(withID: f.research)?.children.count == 2) // no child added
        #expect(undo.undoActionName == "Expand")
    }

    @Test func leafAndCentralTopicOnlySelect() {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        #expect(editor.touchTapTopic(f.launch, at: f.center(f.launch, in: editor), time: 10) == .selected)
        #expect(editor.touchTapTopic(f.rootID, at: f.center(f.rootID, in: editor), time: 20) == .selected)
        deferred.flush()
        #expect(!collapsed(editor, f.rootID) && !undo.canUndo)
        #expect(editor.visiblePalette == .selection && editor.selectedID == f.rootID)
    }

    @Test func tapOnAnotherTopicKeepsTheFold() {
        let f = FoldFixture()
        let (editor, _, deferred) = f.editor()
        editor.touchTapTopic(f.research, at: f.center(f.research, in: editor), time: 10)
        // Another topic within the interval: Research's tap was a single tap.
        #expect(editor.touchTapTopic(f.launch, at: f.center(f.launch, in: editor), time: 10.1) == .selected)
        #expect(collapsed(editor, f.research) && editor.selectedID == f.launch)
        deferred.flush()
        #expect(collapsed(editor, f.research) && editor.visiblePalette == .selection && editor.selectedID == f.launch)
        // The fading branch is not tappable / selectable meanwhile.
        #expect(editor.recentTapFold == nil)
    }

    @Test func foldStaysWhenEditingOrPencilActs() {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        editor.touchTapTopic(f.research, at: f.center(f.research, in: editor), time: 10)
        editor.beginEditing(f.research) // Space / F2 within the interval
        deferred.flush()
        #expect(collapsed(editor, f.research) && editor.editingID == f.research)
        editor.commitEditing()
        #expect(undo.undoActionName == "Collapse")

        let (pencil, _, deferred2) = f.editor()
        pencil.touchTapTopic(f.research, at: f.center(f.research, in: pencil), time: 10)
        pencil.pencilDoubleTap(preference: .switchEraser) // adds a child to the selection (expands it)
        deferred2.flush()
        #expect(!collapsed(pencil, f.research) && pencil.editingID != nil)
        #expect(pencil.model.map.node(withID: f.research)?.children.count == 3)
    }

}

// MARK: - Double-tap adds a child

struct DoubleTapAddChildTests {
    @Test func doubleTapOnExpandedTopicRestoresItAndAddsOneStep() throws {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        let before = editor.model.map
        let point = f.center(f.research, in: editor)
        let frame = editor.screenFrame(of: f.research)!
        #expect(editor.touchTapTopic(f.research, at: point, time: 5) == .collapsed)
        #expect(collapsed(editor, f.research) && editor.foldEcho != nil)
        #expect(editor.touchTapTopic(f.research, at: CGPoint(x: point.x + 4, y: point.y), time: 5.2) == .addedChild)
        // Unfolded again in the same change: the fading branch is real again.
        #expect(!collapsed(editor, f.research) && editor.foldEcho == nil)
        #expect(editor.drawnNode(f.interviews, in: editor.scene)?.isFading == false)
        deferred.flush() // the first tap's palette is stale now
        #expect(!collapsed(editor, f.research))
        let child = try #require(editor.editingID)
        #expect(editor.model.map.parentID(of: child) == f.research)
        #expect(editor.model.map.node(withID: f.research)?.children.last?.id == child)
        // Named right away: default text all selected (keyboard / Scribble replace it).
        #expect(editor.draftText == "Subtopic" && editor.editSelectsAll && editor.selectedID == child)
        #expect(editor.visiblePalette == nil)
        #expect(moved(editor, f.research, from: frame) < 1)
        editor.draftText = "Personas"
        editor.commitEditing()
        #expect(editor.model.map.node(withID: child)?.text == "Personas")
        // Exactly one undo step (Add Topic + name); the Collapse is gone.
        #expect(undo.undoActionName == "Add Topic" && !undo.canRedo)
        undo.undo()
        #expect(editor.model.map == before && !undo.canUndo)
        #expect(!collapsed(editor, f.research))
    }

    @Test func doubleTapOnCollapsedTopicExpandsAndAddsInOneStep() throws {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        let before = editor.model.map
        let point = f.center(f.design, in: editor)
        let frame = editor.screenFrame(of: f.design)!
        #expect(editor.touchTapTopic(f.design, at: point, time: 5) == .expanded)
        #expect(editor.touchTapTopic(f.design, at: point, time: 5.25) == .addedChild)
        deferred.flush()
        let child = try #require(editor.editingID)
        #expect(!collapsed(editor, f.design))
        #expect(editor.model.map.node(withID: f.design)?.children.map(\.id) == [f.wireframes, child])
        #expect(moved(editor, f.design, from: frame) < 1)
        editor.commitEditing()
        // One step: the first tap's Expand was folded into Add Topic.
        #expect(undo.undoActionName == "Add Topic")
        undo.undo()
        #expect(editor.model.map == before && !undo.canUndo && collapsed(editor, f.design))
    }

    @Test func lateSecondTapAfterTheFadeStillOneStep() throws {
        // Edge: the fading branch already left the canvas (timer fired just
        // before a second tap still inside the interval): same result.
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        let before = editor.model.map
        let point = f.center(f.research, in: editor)
        editor.touchTapTopic(f.research, at: point, time: 5)
        deferred.flush()
        #expect(collapsed(editor, f.research) && editor.foldEcho == nil)
        #expect(editor.touchTapTopic(f.research, at: point, time: 5.29) == .addedChild)
        let child = try #require(editor.editingID)
        #expect(!collapsed(editor, f.research) && editor.model.map.parentID(of: child) == f.research)
        #expect(editor.visiblePalette == nil && editor.editingID == child)
        editor.commitEditing()
        undo.undo()
        #expect(editor.model.map == before && !undo.canUndo)
    }

    @Test func foldNotRevertedWhenSomethingElseChangedMeanwhile() throws {
        let f = FoldFixture()
        let (editor, undo, _) = f.editor()
        let point = f.center(f.research, in: editor)
        editor.touchTapTopic(f.research, at: point, time: 5)
        // E.g. a sync merge changed the map between the taps: no blind undo.
        editor.recentTapFold?.mapAfter.root.text = "Changed elsewhere"
        #expect(editor.touchTapTopic(f.research, at: point, time: 5.1) == .addedChild)
        #expect(!collapsed(editor, f.research)) // addChild expands its parent
        editor.commitEditing()
        #expect(undo.undoActionName == "Add Topic")
        undo.undo()
        #expect(undo.undoActionName == "Collapse")
    }

    @Test func doubleTapOnLeafAndCentralTopic() throws {
        let f = FoldFixture()
        let (editor, _, _) = f.editor()
        let point = f.center(f.launch, in: editor)
        editor.touchTapTopic(f.launch, at: point, time: 5)
        #expect(editor.touchTapTopic(f.launch, at: point, time: 5.1) == .addedChild)
        let child = try #require(editor.editingID)
        #expect(editor.model.map.parentID(of: child) == f.launch && editor.draftText == "Subtopic")
        editor.commitEditing()

        let root = f.center(f.rootID, in: editor)
        editor.touchTapTopic(f.rootID, at: root, time: 10)
        #expect(editor.touchTapTopic(f.rootID, at: root, time: 10.1) == .addedChild)
        let main = try #require(editor.editingID)
        #expect(editor.model.map.parentID(of: main) == f.rootID && editor.draftText == "Main Topic")
        #expect(!collapsed(editor, f.rootID))
    }

    @Test func tooSlowOrTooFarIsTwoSingleTaps() {
        let f = FoldFixture()
        let (editor, _, deferred) = f.editor()
        let point = f.center(f.design, in: editor)
        #expect(editor.touchTapTopic(f.design, at: point, time: 5) == .expanded)
        #expect(editor.touchTapTopic(f.design, at: point, time: 5 + TapSequence.maxInterval + 0.01) == .collapsed)
        deferred.flush()
        #expect(collapsed(editor, f.design) && editor.editingID == nil)
        let far = CGPoint(x: point.x + TapSequence.maxDistance + 5, y: point.y)
        #expect(editor.touchTapTopic(f.design, at: point, time: 10) == .expanded)
        #expect(editor.touchTapTopic(f.design, at: far, time: 10.1) == .collapsed)
        #expect(editor.editingID == nil)
    }

    @Test func noDoubleTapRenameAnymore() {
        let f = FoldFixture()
        let (editor, _, _) = f.editor()
        let point = f.center(f.launch, in: editor)
        editor.touchTapTopic(f.launch, at: point, time: 5)
        editor.touchTapTopic(f.launch, at: point, time: 5.1)
        #expect(editor.editingID != f.launch)
        #expect(editor.model.map.node(withID: f.launch)?.text == "Launch")
        // A tap on the topic being edited belongs to its text field.
        let edited = editor.editingID!
        #expect(editor.touchTapTopic(edited, at: .zero, time: 6) == .ignored)
    }

    @Test func renamePathsStillWork() {
        let f = FoldFixture()
        let (editor, _, _) = f.editor()
        editor.select(f.launch)
        editor.palette.showForSelection()
        editor.performPaletteAction(.rename)
        #expect(editor.editingID == f.launch && editor.editSelectsAll)
        editor.commitEditing()
        #expect(KeyCommandMap.command(key: .space, modifiers: [], characters: " ") == .edit)
        #expect(KeyCommandMap.command(key: KeyEquivalent(Character(KeyCommandMap.f2)), modifiers: [],
                                      characters: "UIKeyInputF2") == .edit)
        #if os(iOS)
        #expect(KeyCommandMap.f2Characters.contains(UIKeyCommand.f2))
        #endif
        editor.beginScribble(on: f.design)
        #expect(editor.editingID == f.design)
    }
}

// MARK: - Toggle, palette, Select mode, accessories

struct TapFoldInteractionTests {
    @Test func collapseToggleIsItsOwnToggle() {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        let frame = editor.screenFrame(of: f.research)!
        editor.touchTapTopic(f.research, at: f.center(f.research, in: editor), time: 10)
        #expect(collapsed(editor, f.research))
        // "+N" tapped within the interval: unfolds again (no double-tap child).
        editor.tapCollapseToggle(f.research)
        #expect(!collapsed(editor, f.research) && moved(editor, f.research, from: frame) < 1)
        #expect(Set(editor.drawnOrder).count == editor.drawnOrder.count)
        deferred.flush()
        #expect(!collapsed(editor, f.research) && editor.editingID == nil)
        #expect(editor.visiblePalette == .selection && editor.selectedID == f.research)
        undo.undo()
        undo.undo()
        #expect(!collapsed(editor, f.research) && !undo.canUndo)
        // "+N" expands; a following topic tap is not a double-tap.
        editor.tapCollapseToggle(f.design)
        #expect(!collapsed(editor, f.design))
        #expect(editor.touchTapTopic(f.design, at: f.center(f.design, in: editor), time: 10.1) == .collapsed)
    }

    @Test func paletteHiddenWhileFoldAnimatesThenOnTopic() {
        let f = FoldFixture()
        let (editor, _, deferred) = f.editor()
        let point = f.center(f.research, in: editor)
        editor.touchTapTopic(f.launch, at: f.center(f.launch, in: editor), time: 1)
        deferred.flush()
        #expect(editor.visiblePalette == .selection)
        // Tap a parent: the palette goes away during the fold, never moves with it.
        editor.touchTapTopic(f.research, at: point, time: 5)
        #expect(collapsed(editor, f.research) && editor.visiblePalette == nil)
        deferred.flush()
        #expect(editor.visiblePalette == .selection && editor.selectedID == f.research)
        #expect(editor.paletteContext.isCollapsed && editor.paletteContext.hasChildren)
        // Tapping it again (palette showing) unfolds: hidden, then back.
        #expect(editor.touchTapTopic(f.research, at: point, time: 9) == .expanded)
        #expect(editor.visiblePalette == nil)
        deferred.flush()
        #expect(editor.visiblePalette == .selection)
        // A background tap within the interval cancels the palette, not the fold.
        editor.touchTapTopic(f.research, at: point, time: 20)
        editor.touchTapBackground()
        editor.select(nil)
        deferred.flush()
        #expect(collapsed(editor, f.research) && editor.visiblePalette == nil)
    }

    @Test func leafWithPaletteStillHidesOnTap() {
        let f = FoldFixture()
        let (editor, _, deferred) = f.editor()
        let point = f.center(f.launch, in: editor)
        editor.touchTapTopic(f.launch, at: point, time: 1)
        deferred.flush()
        #expect(editor.touchTapTopic(f.launch, at: point, time: 5) == .hidPalette)
        #expect(editor.visiblePalette == nil)
    }

    @Test func selectModeTapsToggleSelectionNeverFold() {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        editor.isSelectMode = true
        let research = f.center(f.research, in: editor)
        #expect(editor.touchTapTopic(f.research, at: research, time: 1) == .toggled)
        #expect(editor.touchTapTopic(f.design, at: f.center(f.design, in: editor), time: 1.1) == .toggled)
        // Quick second tap on Research: deselects it, no double-tap child.
        #expect(editor.touchTapTopic(f.research, at: research, time: 1.2) == .toggled)
        deferred.flush()
        deferred.flush()
        #expect(editor.selectedIDs == [f.design])
        #expect(!collapsed(editor, f.research) && collapsed(editor, f.design))
        #expect(!undo.canUndo && editor.editingID == nil)
        #expect(editor.visiblePalette == .selection)
    }

    @Test func accessoryButtonTapsNeitherFoldNorDoubleTap() {
        let f = FoldFixture()
        let (editor, undo, deferred) = f.editor()
        let point = f.center(f.research, in: editor)
        // Checkbox / link / attachment icon: its button noted the tap.
        editor.noteAccessoryTap(on: f.research, time: 10)
        #expect(editor.touchTapTopic(f.research, at: point, time: 10.01) == .accessory)
        editor.noteAccessoryTap(on: f.research, time: 10.2)
        #expect(editor.touchTapTopic(f.research, at: point, time: 10.19) == .accessory)
        deferred.flush()
        #expect(!collapsed(editor, f.research) && !undo.canUndo && editor.editingID == nil)
        // A real tap afterwards is a fresh single tap (not the 2nd of a double).
        #expect(editor.touchTapTopic(f.research, at: point, time: 11) == .collapsed)
        #expect(editor.touchTapTopic(f.research, at: point, time: 11.1) == .addedChild)
        #expect(!collapsed(editor, f.research) && undo.undoActionName == "Add Topic")
    }

    @Test func picksAndLongPressStillWin() {
        let f = FoldFixture()
        let (editor, _, deferred) = f.editor()
        editor.beginRelationship(from: f.launch)
        #expect(editor.touchTapTopic(f.research, at: f.center(f.research, in: editor), time: 1) == .picked)
        #expect(!collapsed(editor, f.research) && editor.model.map.relationships.count == 1)
        editor.touchTapTopic(f.design, at: f.center(f.design, in: editor), time: 5)
        editor.touchLongPress(f.design) // context menu: palette gone, no double-tap after it
        deferred.flush()
        #expect(!collapsed(editor, f.design) && editor.visiblePalette == nil)
        #expect(editor.recentTapFold == nil)
        #expect(editor.touchTapTopic(f.design, at: f.center(f.design, in: editor), time: 5.1) == .collapsed)
    }

    @Test func gestureHelpDescribesV2() {
        let rows = GestureHelp.sections.flatMap(\.rows)
        let double = rows.first { $0.gesture == "Double-tap a topic" }
        #expect(double?.action.contains("child") == true)
        #expect(rows.first { $0.gesture == "Tap a topic" }?.action.contains("fold") == true)
        #expect(!rows.contains { $0.action == "Rename it" })
        #expect(rows.contains { $0.gesture == "Rename" && $0.action.contains("Edit") })
        #expect(rows.contains { $0.gesture.contains("F2") })
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}
