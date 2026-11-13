import CoreGraphics
import Foundation
import Testing
@testable import MindMap

/// Favorites: mark / unmark (one undo step), persistence, the derived list,
/// read-only gate, the Favorites panel (position, state, row "show").
@MainActor
struct FavoritesTests {
    private func makeEditor(readOnly: Bool = false, favoritesPanel: TaskPanelState? = nil)
        -> (editor: EditorController, undo: UndoManager, alpha: UUID, beta: UUID, gamma: UUID, free: UUID) {
        let t = TaskTests.makeMap()
        var map = t.map
        map.isReadOnly = readOnly
        map.favoritesPanel = favoritesPanel
        let editor = EditorController(model: MindMapModel(map: map))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.updateViewSize(CGSize(width: 1200, height: 900))
        return (editor, undo, t.alpha, t.beta, t.gamma, t.free)
    }

    @Test func markAndUnmarkAreSingleUndoSteps() {
        let t = TaskTests.makeMap()
        let model = MindMapModel(map: t.map)
        let undo = UndoTests.makeUndoManager()
        #expect(model.setFavorite([t.alpha], true, undoManager: undo))
        #expect(model.map.node(withID: t.alpha)?.isFavorite == true)
        #expect(undo.undoActionName == "Mark as Favorite")
        undo.undo()
        #expect(model.map.node(withID: t.alpha)?.isFavorite == false)
        undo.redo()
        #expect(model.setFavorite([t.alpha], false, undoManager: undo))
        #expect(undo.undoActionName == "Remove from Favorites")
        #expect(!model.setFavorite([t.alpha], false, undoManager: undo)) // no change
    }

    @Test func favoriteIsSavedOnlyWhenTrue() throws {
        var t = TaskTests.makeMap()
        let plain = String(decoding: try JSONEncoder().encode(t.map), as: UTF8.self)
        #expect(!plain.contains("isFavorite") && !plain.contains("favoritesPanel"))
        t.map.favoritesPanel = TaskPanelState(position: CGPoint(x: 5, y: 6), isCollapsed: true)
        let model = MindMapModel(map: t.map)
        model.setFavorite([t.gamma, t.free], true, undoManager: nil)
        let decoded = try JSONDecoder().decode(MindMap.self, from: try JSONEncoder().encode(model.map))
        #expect(decoded == model.map)
        #expect(decoded.node(withID: t.gamma)?.isFavorite == true)
        #expect(decoded.node(withID: t.alpha)?.isFavorite == false)
        #expect(decoded.favoritesPanel == TaskPanelState(position: CGPoint(x: 5, y: 6), isCollapsed: true))
    }

    @Test func multiSelectionToggleIsOneStep() {
        let t = makeEditor()
        let ids = [t.alpha, t.beta]
        t.editor.setSelection(ids)
        t.editor.toggleFavorite(t.alpha)
        #expect(ids.allSatisfy { t.editor.model.map.node(withID: $0)?.isFavorite == true })
        #expect(t.undo.undoActionName == "Mark as Favorite")
        #expect(t.editor.targetsAreFavorites(for: t.alpha))
        t.editor.toggleFavorite(t.alpha) // all are favorites: remove all
        #expect(ids.allSatisfy { t.editor.model.map.node(withID: $0)?.isFavorite == false })
        t.undo.undo()
        #expect(ids.allSatisfy { t.editor.model.map.node(withID: $0)?.isFavorite == true })
        // Mixed: one more topic in the selection that is not a favorite marks all.
        t.editor.model.setFavorite([t.alpha], false, undoManager: nil)
        t.editor.toggleFavorite(t.alpha)
        #expect(ids.allSatisfy { t.editor.model.map.node(withID: $0)?.isFavorite == true })
    }

    @Test func listFollowsMapOrderAndIncludesFloatingTopics() {
        let t = TaskTests.makeMap()
        let model = MindMapModel(map: t.map)
        model.setFavorite([t.free, t.gamma, t.alpha], true, undoManager: nil)
        #expect(model.map.favorites.map(\.text) == ["Alpha", "Gamma", "Free"])
    }

    @Test func readOnlyMapRejectsMarking() {
        let t = makeEditor(readOnly: true)
        t.editor.toggleFavorite(t.alpha)
        #expect(t.editor.model.map.favorites.isEmpty)
        #expect(t.editor.readOnlyNotice != nil)
        #expect(!t.editor.model.setFavorite([t.alpha], true, undoManager: t.undo))
    }

    @Test func panelShowsOnlyWithFavoritesAndStaysBelowTheTasksPanel() throws {
        let t = makeEditor()
        #expect(t.editor.favoritesPanel == nil)
        t.editor.model.setFavorite([t.alpha], true, undoManager: nil)
        let alone = try #require(t.editor.favoritesPanel)
        #expect(alone.isAutoPositioned && alone.entries.map(\.id) == [t.alpha])
        t.editor.model.makeTask(t.beta, undoManager: nil)
        let tasks = try #require(t.editor.taskPanel)
        let below = try #require(t.editor.favoritesPanel)
        #expect(!below.frame.intersects(tasks.frame) && below.frame.minY >= tasks.frame.maxY)
    }

    @Test func panelStatePersistsAndIsUndoable() throws {
        let t = makeEditor()
        let model = t.editor.model
        let undo = t.undo
        model.setFavorite([t.alpha], true, undoManager: nil)
        #expect(model.moveFavoritesPanel(to: CGPoint(x: 40, y: 50), undoManager: undo))
        #expect(model.setFavoritesPanelCollapsed(true, undoManager: undo))
        #expect(undo.undoActionName == "Collapse Favorites Panel")
        let decoded = try JSONDecoder().decode(MindMap.self, from: try JSONEncoder().encode(model.map))
        #expect(decoded.favoritesPanel == TaskPanelState(position: CGPoint(x: 40, y: 50), isCollapsed: true))
        #expect(try #require(t.editor.favoritesPanel).frame.height == TaskPanelLayout.headerHeight)
        undo.undo()
        undo.undo()
        #expect(model.map.favoritesPanel == nil)
    }

    @Test func readOnlyMapMayCollapseButNotMoveThePanel() {
        var map = TaskTests.makeMap().map
        map.root.children[0].isFavorite = true
        map.isReadOnly = true
        let t = (editor: EditorController(model: MindMapModel(map: map)), undo: UndoTests.makeUndoManager())
        t.editor.undoManager = t.undo
        #expect(t.editor.model.setFavoritesPanelCollapsed(true, undoManager: t.undo))
        #expect(!t.editor.model.moveFavoritesPanel(to: CGPoint(x: 1, y: 2), undoManager: t.undo))
    }

    @Test func rowShowSelectsAndExpandsAncestors() {
        let t = makeEditor()
        t.editor.model.setFavorite([t.gamma], true, undoManager: nil)
        #expect(t.editor.model.map.node(withID: t.beta)?.isCollapsed == true)
        t.editor.showFavorite(t.gamma)
        #expect(t.editor.selectedID == t.gamma)
        #expect(t.editor.model.map.node(withID: t.beta)?.isCollapsed == false)
        #expect(t.editor.scene.layout.frames[t.gamma] != nil)
    }
}
