#if DEBUG
import Foundation

/// DEBUG-only launch hooks for screenshots without UI automation:
/// `MINDMAP_DEBUG_NOTE=icon` adds a topic with a Markdown note to the open
/// map; `=sheet` also opens the note (sheet on iPad, window on macOS).
/// (simctl: `SIMCTL_CHILD_MINDMAP_DEBUG_NOTE=sheet xcrun simctl launch ...`.)
enum DebugLaunchActions {
    nonisolated(unsafe) private static var didRun = false

    static func run(_ editor: EditorController) {
        guard !didRun, !LaunchEnvironment.isTesting,
              let mode = ProcessInfo.processInfo.environment["MINDMAP_DEBUG_NOTE"] else { return }
        didRun = true
        let model = editor.model
        let topic = model.root.children.first { $0.text == "Research" }?.id
            ?? model.addChild(to: model.root.id, text: "Research", undoManager: editor.undoManager)
        guard let topic else { return }
        var note = model.map.node(withID: topic)?.attachments.first { $0.kind == .markdown }?.id
        if note == nil {
            note = model.addNote(to: topic, undoManager: editor.undoManager)
            if let note {
                let text = "# Research\n\nSources for the **launch plan**:\n\n- interviews\n- [x] survey\n\n> Keep it short.\n"
                model.setAttachmentContent(MarkdownNote.data(text), for: note, undoManager: editor.undoManager)
            }
        }
        editor.select(topic)
        guard mode == "sheet", let note else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { editor.openAttachment(note) }
    }
}
#endif
