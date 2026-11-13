#if DEBUG
import Foundation

/// DEBUG-only screenshot hook for "Lock Editing" (WP15), no UI automation:
/// `MINDMAP_DEBUG_READONLY=on` locks the open map (seeding a small one when
/// it has no topics) and selects "Design"; `=notice` also tries an edit
/// (Delete) so the "Map is locked — unlock to edit" notice shows and stays;
/// `=palette` (iPad) shows the read-only action palette on "Research".
/// (simctl: `SIMCTL_CHILD_MINDMAP_DEBUG_READONLY=notice xcrun simctl launch ...`.)
enum DebugReadOnlyActions {
    nonisolated(unsafe) private static var didRun = false

    static func run(_ editor: EditorController) {
        guard !didRun, !LaunchEnvironment.isTesting,
              let mode = ProcessInfo.processInfo.environment["MINDMAP_DEBUG_READONLY"] else { return }
        didRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { perform(mode, editor) }
    }

    private static func perform(_ mode: String, _ editor: EditorController) {
        if editor.model.root.children.isEmpty { seed(editor) }
        if editor.isReadOnly == false { editor.setReadOnly(true) }
        editor.zoomToFit()
        let design = editor.model.root.children.first { $0.text == "Design" }?.id
        let research = editor.model.root.children.first { $0.text == "Research" }?.id
        editor.select(design ?? editor.model.root.id)
        switch mode {
        case "notice":
            // Keep the notice up for the screenshot.
            editor.noticeScheduler = { _, _ in }
            editor.perform(.delete)
        case "palette":
            if let research { editor.select(research) }
            editor.palette.showForSelection()
        default:
            break
        }
    }

    private static func seed(_ editor: EditorController) {
        var budget = Node(text: "Budget")
        budget.task = TaskInfo(priority: .high)
        let map = MindMap(root: Node(text: "Product Launch", layoutStyle: .balancedMap, children: [
            Node(text: "Research", children: [Node(text: "Survey"), Node(text: "Interviews")]),
            Node(text: "Design", children: [Node(text: "Wireframes"), Node(text: "Prototype")]),
            Node(text: "Launch", children: [Node(text: "Marketing"), Node(text: "Press kit")]),
            budget,
        ]))
        editor.model.debugReplaceMap(map)
    }
}
#endif
