#if DEBUG
import Foundation
import PencilKit
#if os(macOS)
import AppKit
typealias DebugInkColor = NSColor
#else
import UIKit
typealias DebugInkColor = UIColor
#endif

/// DEBUG-only launch hooks for screenshots without UI automation:
/// - `MINDMAP_DEBUG_NOTE=icon` adds a topic with a Markdown note to the open
///   map; `=sheet` also opens the note (sheet on iPad, window on macOS).
/// - `MINDMAP_DEBUG_DRAWING=icon|sheet`: the same with a handwritten note
///   pre-seeded with `DebugDrawing.sample()` (full-screen canvas on iPad);
///   `=undo` also adds a big "Draw" step 3 s after opening and undoes it 3 s
///   later (checks that the open canvas follows store changes).
/// - `MINDMAP_DEBUG_FILE=icon` attaches a generated "Project Brief.pdf" and
///   "Mockup.png" to topic "Files"; `=sheet` opens the PDF (sheet on iPad,
///   window on macOS), `=image` the PNG, `=picker` shows the Attach File…
///   picker, `=many` adds 3 more files (collapsed icon row + count badge).
/// (simctl: `SIMCTL_CHILD_MINDMAP_DEBUG_NOTE=sheet xcrun simctl launch ...`.)
enum DebugLaunchActions {
    nonisolated(unsafe) private static var didRun = false

    static func run(_ editor: EditorController) {
        guard !didRun, !LaunchEnvironment.isTesting else { return }
        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["MINDMAP_DEBUG_NOTE"] {
            didRun = true
            seedNote(editor, open: mode == "sheet")
        } else if let mode = environment["MINDMAP_DEBUG_FILE"] {
            didRun = true
            seedFiles(editor, mode: mode)
        } else if let mode = environment["MINDMAP_DEBUG_DRAWING"] {
            didRun = true
            seedDrawing(editor, open: mode == "sheet" || mode == "undo", exerciseUndo: mode == "undo")
        }
    }

    private static func topic(_ text: String, _ editor: EditorController) -> UUID? {
        let model = editor.model
        return model.root.children.first { $0.text == text }?.id
            ?? model.addChild(to: model.root.id, text: text, undoManager: editor.undoManager)
    }

    private static func seedNote(_ editor: EditorController, open: Bool) {
        let model = editor.model
        guard let topic = topic("Research", editor) else { return }
        var note = model.map.node(withID: topic)?.attachments.first { $0.kind == .markdown }?.id
        if note == nil {
            note = model.addNote(to: topic, undoManager: editor.undoManager)
            if let note {
                let text = "# Research\n\nSources for the **launch plan**:\n\n- interviews\n- [x] survey\n\n> Keep it short.\n"
                model.setAttachmentContent(MarkdownNote.data(text), for: note, undoManager: editor.undoManager)
            }
        }
        editor.select(topic)
        guard open, let note else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { editor.openAttachment(note) }
    }

    private static func seedFiles(_ editor: EditorController, mode: String) {
        let model = editor.model
        guard let topic = topic("Files", editor) else { return }
        var files = model.map.node(withID: topic)?.attachments.filter { $0.kind == .file } ?? []
        if files.isEmpty, let folder = try? DebugSampleFiles.folder() {
            var urls = [try? DebugSampleFiles.writePDF(in: folder), try? DebugSampleFiles.writePNG(in: folder)]
            if mode == "many" {
                urls.append(try? DebugSampleFiles.writePDF(named: "Budget 2027.pdf", in: folder))
                urls.append(try? DebugSampleFiles.writePNG(named: "Whiteboard photo.png", in: folder))
                urls.append(try? DebugSampleFiles.writePDF(named: "Contract.pdf", in: folder))
            }
            for url in urls.compactMap({ $0 }) {
                _ = try? model.importFile(at: url, to: topic, undoManager: editor.undoManager)
            }
            files = model.map.node(withID: topic)?.attachments.filter { $0.kind == .file } ?? []
        }
        editor.select(topic)
        switch mode {
        case "sheet", "image":
            let wanted = mode == "image" ? "png" : "pdf"
            guard let file = files.first(where: { $0.fileName.hasSuffix("." + wanted) }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { editor.openAttachment(file.id) }
        case "picker":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { editor.beginAttachFile(to: topic) }
        default:
            break
        }
    }

    private static func seedDrawing(_ editor: EditorController, open: Bool, exerciseUndo: Bool) {
        let model = editor.model
        guard let topic = topic("Sketches", editor) else { return }
        var drawing = model.map.node(withID: topic)?.attachments.first { $0.kind == .drawing }?.id
        if drawing == nil {
            drawing = model.addDrawing(to: topic, content: DebugDrawing.sample().dataRepresentation(),
                                       undoManager: editor.undoManager)
        }
        editor.select(topic)
        guard open, let drawing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { editor.openAttachment(drawing) }
        guard exerciseUndo else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
            var updated = HandwrittenNote.drawing(model.content(of: drawing))
            let zigzag = (0...16).map { CGPoint(x: 120 + CGFloat($0) * 40, y: $0 % 2 == 0 ? 640 : 760) }
            updated.strokes.append(DebugDrawing.stroke(zigzag, color: .systemPurple, width: 10))
            model.setAttachmentContent(updated.dataRepresentation(), for: drawing, actionName: "Draw",
                                       coalescing: false, undoManager: editor.undoManager)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.8) { editor.undoManager?.undo() }
    }
}

/// Synthetic handwriting-like strokes (screenshots, tests).
enum DebugDrawing {
    static func stroke(_ points: [CGPoint], color: DebugInkColor, width: CGFloat = 4,
                       ink: PKInk.InkType = .pen) -> PKStroke {
        let strokePoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: TimeInterval(index) * 0.01,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(ink, color: color),
                        path: PKStrokePath(controlPoints: strokePoints, creationDate: Date(timeIntervalSince1970: 0)))
    }

    static func sample() -> PKDrawing {
        var strokes: [PKStroke] = []
        // Loopy "handwriting" line.
        let writing = (0...360).map { i -> CGPoint in
            let t = CGFloat(i) / 360 * 9 * .pi
            return CGPoint(x: 80 + CGFloat(i) * 1.6 + 32 * cos(t), y: 150 - 30 * sin(t) + 6 * sin(t / 3))
        }
        strokes.append(stroke(writing, color: .black, width: 3.5))
        // Underline.
        strokes.append(stroke((0...40).map { CGPoint(x: 80 + CGFloat($0) * 15, y: 215 + 3 * sin(CGFloat($0) / 4)) },
                              color: DebugInkColor(red: 0.18, green: 0.44, blue: 0.88, alpha: 1), width: 3))
        // Box with an arrow to a circle.
        let box: [CGPoint] = [CGPoint(x: 100, y: 300), CGPoint(x: 360, y: 302), CGPoint(x: 358, y: 440),
                              CGPoint(x: 102, y: 438), CGPoint(x: 100, y: 300)]
        strokes.append(stroke(interpolate(box), color: .black, width: 3))
        strokes.append(stroke(interpolate([CGPoint(x: 370, y: 370), CGPoint(x: 560, y: 370)]),
                              color: DebugInkColor(red: 0.85, green: 0.27, blue: 0.23, alpha: 1), width: 4))
        strokes.append(stroke(interpolate([CGPoint(x: 530, y: 345), CGPoint(x: 562, y: 370), CGPoint(x: 530, y: 395)]),
                              color: DebugInkColor(red: 0.85, green: 0.27, blue: 0.23, alpha: 1), width: 4))
        let circle = (0...120).map { i -> CGPoint in
            let t = CGFloat(i) / 120 * 2 * .pi
            return CGPoint(x: 680 + 95 * cos(t), y: 370 + 70 * sin(t))
        }
        strokes.append(stroke(circle, color: DebugInkColor(red: 0.18, green: 0.62, blue: 0.34, alpha: 1), width: 3))
        // Highlighter mark.
        strokes.append(stroke(interpolate([CGPoint(x: 90, y: 520), CGPoint(x: 700, y: 520)]),
                              color: DebugInkColor(red: 1, green: 0.85, blue: 0.2, alpha: 1), width: 24, ink: .marker))
        return PKDrawing(strokes: strokes)
    }

    private static func interpolate(_ corners: [CGPoint], step: CGFloat = 6) -> [CGPoint] {
        var result: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            result += (0..<n).map { i in
                let t = CGFloat(i) / CGFloat(n)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
        return result + [corners.last!]
    }
}
#endif
