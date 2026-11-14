#if DEBUG && os(iOS)
import Foundation

/// DEBUG-only screenshot hooks for the iPad touch UX (WP11), no UI automation:
/// `MINDMAP_DEBUG_TOUCH=palette` selects topic "Design" and shows its action
/// palette; `=multi` selects three topics (multi palette); `=insert` shows
/// the Insert palette (Pencil squeeze over empty canvas); `=hover` fakes a
/// Pencil hover over "Launch" (highlight + "+" handle) next to the selected
/// "Design"; `=help` opens the Gestures sheet; `=root` palette on the
/// central topic; `=tapcollapse` taps "Research" (WP16: selected, its branch
/// folds at once, palette after the double-tap interval); `=tapexpand` taps
/// the collapsed "Research" again; `=doubletap` double-taps the expanded
/// "Design" (the first tap folds it, the second unfolds it again and adds a
/// child inside, being named). `MINDMAP_DEBUG_TOUCH_DELAY=<s>` waits that
/// long before the tap(s) (screen recording). Seeds a small map when the open one has no
/// such topics.
/// (simctl: `SIMCTL_CHILD_MINDMAP_DEBUG_TOUCH=palette xcrun simctl launch ...`.)
enum DebugTouchActions {
    nonisolated(unsafe) private static var didRun = false
    /// Editor of the canvas that appeared last (a document opened after
    /// launch / a re-created ContentView replaces a throwaway one).
    nonisolated(unsafe) private static weak var latest: EditorController?

    static func run(_ editor: EditorController) {
        guard !LaunchEnvironment.isTesting,
              let mode = ProcessInfo.processInfo.environment["MINDMAP_DEBUG_TOUCH"] else { return }
        latest = editor
        guard !didRun else { return }
        didRun = true
        let delay = ProcessInfo.processInfo.environment["MINDMAP_DEBUG_TOUCH_DELAY"].flatMap(Double.init) ?? 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { perform(mode, latest ?? editor) }
    }

    private static func perform(_ mode: String, _ editor: EditorController) {
        let ids = seed(editor)
        editor.zoomToFit()
        switch mode {
        case "multi":
            editor.setSelection([ids.research, ids.survey, ids.launch], primary: ids.launch)
            editor.palette.showForSelection()
        case "insert":
            editor.select(ids.design)
            editor.palette.showInsert(at: CGPoint(x: editor.viewSize.width * 0.5, y: editor.viewSize.height * 0.82))
        case "hover":
            editor.select(ids.design)
            editor.pencilHoveredID = ids.launch
        case "help":
            editor.isGestureHelpPresented = true
        case "tapcollapse", "tapexpand":
            let point = center(ids.research, editor)
            editor.touchTapTopic(ids.research, at: point)
            if mode == "tapexpand" {
                // Second, separate tap once the first one has folded it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    editor.touchTapTopic(ids.research, at: point)
                }
            }
        case "doubletap":
            let point = center(ids.design, editor)
            let time = ProcessInfo.processInfo.systemUptime
            editor.touchTapTopic(ids.design, at: point, time: time)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                editor.touchTapTopic(ids.design, at: point, time: time + 0.15)
            }
        case "root":
            editor.select(editor.model.root.id)
            editor.palette.showForSelection()
        default:
            editor.select(ids.design)
            editor.palette.showForSelection()
        }
    }

    private static func center(_ id: UUID, _ editor: EditorController) -> CGPoint {
        let frame = editor.screenFrame(of: id) ?? .zero
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private struct Seeded {
        var research: UUID, survey: UUID, design: UUID, launch: UUID
    }

    private static func seed(_ editor: EditorController) -> Seeded {
        let model = editor.model
        let undo = editor.undoManager
        func child(_ text: String, of parent: UUID) -> UUID {
            if let existing = model.map.node(withID: parent)?.children.first(where: { $0.text == text }) {
                return existing.id
            }
            return model.addChild(to: parent, text: text, undoManager: undo) ?? parent
        }
        let root = model.root.id
        let research = child("Research", of: root)
        _ = child("Interviews", of: research)
        let survey = child("Survey", of: research)
        let design = child("Design", of: root)
        _ = child("Wireframes", of: design)
        _ = child("Visual style", of: design)
        let launch = child("Launch", of: root)
        _ = child("Budget", of: root)
        return Seeded(research: research, survey: survey, design: design, launch: launch)
    }
}
#endif
