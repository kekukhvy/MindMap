import SwiftUI
import Testing
@testable import MindMap

/// Reference snapshot of tasks on topics (open, done, priorities, due chips
/// incl. overdue, floating task) and the Tasks panel. On macOS the PNG is
/// written to the app container temp dir as `tasks.png` (copy to Tools/preview/).
@MainActor
struct TaskSnapshotTests {
    static func sampleMap(now: Date = Date()) -> MindMap {
        let calendar = Calendar.current
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        }
        let palette = ColorTheme.rainbowPalette
        let design = Node(text: "Design", customColor: palette[0], children: [
            Node(text: "Wireframes", task: TaskInfo(isDone: true, completedAt: now)),
            Node(text: "Visual polish", task: TaskInfo(priority: .medium, dueDate: day(1))),
        ])
        let build = Node(text: "Build", customColor: palette[2], children: [
            Node(text: "API client", task: TaskInfo(priority: .high, dueDate: day(-2))),
            Node(text: "Offline mode", task: TaskInfo(priority: .low)),
            Node(text: "Architecture notes"),
        ])
        let marketing = Node(text: "Marketing", customColor: palette[4], children: [
            Node(text: "Website copy", task: TaskInfo(dueDate: day(0))),
            Node(text: "Press kit", task: TaskInfo(dueDate: day(9))),
        ])
        let qa = Node(text: "QA pass", customColor: palette[5], task: TaskInfo(priority: .high, dueDate: day(4)))
        let root = Node(text: "Launch Plan", layoutStyle: .rightMap, children: [design, build, marketing, qa])
        let inbox = Node(text: "Call the printer", task: TaskInfo())
        return MindMap(root: root, floatingTopics: [FloatingTopic(node: inbox, position: CGPoint(x: -40, y: 210))])
    }

    @Test func renderTasksSnapshot() throws {
        let editor = EditorController(model: MindMapModel(map: TaskSnapshotTests.sampleMap()))
        let size = CGSize(width: 1100, height: 560)
        editor.updateViewSize(size)
        let bounds = editor.contentBoundsIncludingPanel
        editor.viewport = Viewport(scale: 1, offset: CGPoint(x: (size.width / 2 - bounds.midX).rounded(),
                                                             y: (size.height / 2 - bounds.midY).rounded()))
        let panel = try #require(editor.taskPanel)
        #expect(panel.openCount == 7)
        for frame in editor.scene.layout.frames.values { #expect(!frame.intersects(panel.frame)) }
        editor.select(panel.visibleEntries[1].id)
        let view = CanvasView(editor: editor).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 2200)
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks.png")
        try data.write(to: url)
        print("SNAPSHOT \(url.path)")
        #endif
    }
}
