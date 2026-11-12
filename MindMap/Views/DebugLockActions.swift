#if DEBUG
import Foundation

/// DEBUG-only launch hooks for WP12 screenshots (no UI automation):
/// - `MINDMAP_DEBUG_LOCK=lock`: seeds topics + a note into the open map (if
///   it is plain), locks it (real keychain), saves, relocks after 1.5 s and
///   shows the lock screen (which prompts for Face ID / Touch ID by itself).
///   A map that is already locked just shows its lock screen.
/// - `=note`: locks the note of topic "Diary" and opens it (the editor asks
///   for Face ID by itself).
/// Writes `<tmp>/lock-report.txt` (state, package entries, whether the
/// topic text occurs in any file of the saved package) 4 s after start.
/// simctl: `SIMCTL_CHILD_MINDMAP_DEBUG_LOCK=lock xcrun simctl launch …`;
/// Face ID: `xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.pearl.match`.
enum DebugLockActions {
    nonisolated(unsafe) private static var didRun = false
    static let secretText = "Secret salary plan"

    static func run(_ model: MindMapModel, title: String) {
        guard !didRun, !LaunchEnvironment.isTesting,
              let mode = ProcessInfo.processInfo.environment["MINDMAP_DEBUG_LOCK"] else { return }
        didRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { start(model, mode: mode) }
    }

    private static func editor(of model: MindMapModel) -> EditorController? {
        EditorController.debugInstances.compactMap(\.editor).last { $0.model === model }
    }

    private static func start(_ model: MindMapModel, mode: String) {
        var lines = ["mode=\(mode)", "initial locked=\(model.lock.isMapLocked) sealed=\(model.lock.isSealed)"]
        if !model.lock.isMapLocked, let editor = editor(of: model) {
            let undo = editor.undoManager
            if !model.root.children.contains(where: { $0.text == secretText }) {
                model.addChild(to: model.root.id, text: secretText, undoManager: undo)
                model.addChild(to: model.root.id, text: "Health notes", undoManager: undo)
                if let diary = model.addChild(to: model.root.id, text: "Diary", undoManager: undo),
                   let note = model.addNote(to: diary, undoManager: undo) {
                    model.setAttachmentContent(MarkdownNote.data("# Diary\n\nPrivate thoughts.\n"), for: note,
                                               undoManager: undo)
                }
            }
            if mode == "note" {
                lockDiaryNote(model, editor: editor, lines: &lines)
            } else {
                do {
                    let storage = try model.lockMap(undoManager: undo)
                    lines.append("lockMap storage=\(storage)")
                } catch {
                    lines.append("lockMap error=\(error)")
                }
                model.lock.request = .saveAndPurgeVersions
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.lock.relock(autoPrompt: true) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { writeReport(model, lines: lines) }
    }

    private static func lockDiaryNote(_ model: MindMapModel, editor: EditorController, lines: inout [String]) {
        guard let diary = model.root.children.first(where: { $0.text == "Diary" }),
              let note = diary.attachments.first(where: { $0.kind == .markdown }) else { return }
        if !note.isLocked {
            do {
                let storage = try model.lockNote(note.id, undoManager: editor.undoManager)
                lines.append("lockNote storage=\(storage)")
            } catch {
                lines.append("lockNote error=\(error)")
            }
        }
        model.lock.request = .saveAndPurgeVersions
        editor.select(diary.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { editor.openAttachment(note.id) }
    }

    private static func writeReport(_ model: MindMapModel, lines: [String]) {
        var lines = lines
        lines.append("now locked=\(model.lock.isMapLocked) sealed=\(model.lock.isSealed) screen=\(model.lock.isShowingLockScreen)")
        if let url = EditorController.debugInstances.compactMap(\.editor).last(where: { $0.model === model })?.documentURL {
            lines.append("file=\(url.path)")
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            var leaks: [String] = []
            for file in files where !file.hasDirectoryPath {
                let rel = file.path.replacingOccurrences(of: url.path + "/", with: "")
                lines.append("entry \(rel)")
                if let data = try? Data(contentsOf: file), data.range(of: Data(secretText.utf8)) != nil {
                    leaks.append(rel)
                }
            }
            lines.append("plaintext leaks=\(leaks)")
        }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("lock-report.txt")
        try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
    }
}
#endif
