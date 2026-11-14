import CoreGraphics
import Foundation

/// Branch a single tap just collapsed (iPad, WP16): its topics and lines stay
/// in the canvas, drawn where they were on screen and fading out with the
/// collapse animation, until the double-tap interval has passed. A
/// double-tap within it re-expands the branch: the same views animate back
/// (no vanish-and-reappear flash), while the model change was committed at
/// once (clean undo).
struct FoldEcho {
    var token: Int
    /// Hidden descendants, draw order.
    var order: [UUID]
    var nodes: [UUID: MapScene.NodeInfo]
    /// Map frames shifted with the anchored topic (screen positions unchanged).
    var frames: [UUID: CGRect]
    var connectors: [MapScene.StyledConnector]

    /// - Parameters:
    ///   - hidden: topics visible in `before` and hidden by the collapse.
    ///   - shift: how far the folded topic moved in map coordinates (the
    ///     viewport moves back by the same amount, WP17 anchoring).
    init(token: Int, hidden: [UUID], before: MapScene, shift: CGPoint) {
        self.token = token
        let set = Set(hidden)
        order = hidden
        nodes = before.nodes.filter { set.contains($0.key) }
        frames = before.layout.frames.filter { set.contains($0.key) }
            .mapValues { $0.offsetBy(dx: shift.x, dy: shift.y) }
        let move = Viewport(scale: 1, offset: shift)
        connectors = before.connectors.filter { set.contains($0.childID) }.map {
            var connector = $0
            connector.geometry = $0.geometry.transformed(by: move)
            connector.isFading = true
            return connector
        }
    }
}

extension EditorController {
    /// Topics the canvas draws: the scene's, then a fading collapsed branch.
    var drawnOrder: [UUID] {
        let scene = scene
        guard let foldEcho else { return scene.order }
        return scene.order + foldEcho.order.filter { scene.nodes[$0] == nil }
    }

    /// What to draw for `id` (map frame); `isFading` = part of `foldEcho`.
    func drawnNode(_ id: UUID, in scene: MapScene) -> (info: MapScene.NodeInfo, frame: CGRect, isFading: Bool)? {
        if let info = scene.nodes[id], let frame = scene.layout.frames[id] { return (info, frame, false) }
        guard let foldEcho, let info = foldEcho.nodes[id], let frame = foldEcho.frames[id] else { return nil }
        return (info, frame, true)
    }

    /// Lines of a fading collapsed branch (not in the scene any more).
    var fadingConnectors: [MapScene.StyledConnector] {
        guard let foldEcho else { return [] }
        let scene = scene
        return foldEcho.connectors.filter { scene.nodes[$0.childID] == nil }
    }

    /// Single tap: folds / unfolds `id` NOW (one undo step, anchored), keeps
    /// a collapsing branch drawn while it fades, and shows the palette once
    /// the double-tap interval (> relayout) has passed.
    func foldByTap(_ id: UUID, paletteToken: Int) {
        let before = scene
        let collapsing = before.nodes[id]?.isCollapsed == false
        let node = model.map.node(withID: id)
        let hidden = collapsing ? before.order.filter { $0 != id && node?.contains($0) == true } : []
        commitEditing()
        tapFoldCounter += 1
        let token = tapFoldCounter
        keepingOnScreen(id) {
            guard model.toggleCollapse(id, undoManager: undoManager) else { return }
            recentTapFold = RecentTapFold(id: id, collapsed: collapsing, mapAfter: model.map)
            if !hidden.isEmpty, let old = before.layout.frames[id], let new = scene.layout.frames[id] {
                foldEcho = FoldEcho(token: token, hidden: hidden, before: before,
                                    shift: CGPoint(x: new.midX - old.midX, y: new.midY - old.midY))
            }
        }
        validateSelection()
        paletteScheduler(TapSequence.maxInterval) { [weak self] in
            self?.palette.fire(paletteToken)
            self?.endFoldEcho(token)
        }
    }

    /// The double-tap interval has passed: the faded branch leaves the canvas.
    func endFoldEcho(_ token: Int) {
        if foldEcho?.token == token { foldEcho = nil }
    }

    /// Second tap of a double-tap: undoes the first tap's fold step (if it
    /// is still the latest change), inside the caller's animated, anchored
    /// change. Returns whether it did.
    @discardableResult
    func revertTapFold(on id: UUID) -> Bool {
        let fold = recentTapFold
        recentTapFold = nil
        foldEcho = nil
        guard let fold, let undoManager,
              fold.canRevert(on: id, map: model.map, canUndo: undoManager.canUndo, canRedo: undoManager.canRedo,
                             undoActionName: undoManager.undoActionName) else { return false }
        isRevertingTapFold = true
        defer { isRevertingTapFold = false }
        undoManager.undo()
        return true
    }

    /// Another gesture took over: the last tap's fold is no longer revertable.
    func forgetTapFold() {
        recentTapFold = nil
    }
}
