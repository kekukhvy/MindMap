#if os(macOS)
import AppKit
import PencilKit
import Testing
@testable import MindMap

/// Real-event test (see `CanvasEventHarness`): clicking a topic's scribble
/// icon in a real document window opens the handwriting window, which
/// renders the stored PKDrawing on a white page and records mouse strokes
/// as "Draw" steps on the document's undo manager.
@MainActor
@Suite(.serialized)
struct DrawingWindowEventTests {
    private func pageView(in view: NSView?) -> DrawingPageView? {
        guard let view else { return nil }
        if let found = view as? DrawingPageView { return found }
        for sub in view.subviews {
            if let found = pageView(in: sub) { return found }
        }
        return nil
    }

    /// Fraction of clearly non-white pixels of `view` (rendered via cacheDisplay).
    private func inkCoverage(_ view: NSView, writeTo name: String? = nil) throws -> Double {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let name, let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        var ink = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if color.redComponent + color.greenComponent + color.blueComponent < 2.4 { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in page: DrawingPageView,
                       time: TimeInterval) throws {
        let window = try #require(page.window)
        let location = page.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
    }

    @Test func clickingScribbleIconOpensRenderedDrawingWindow() async throws {
        UserDefaults.standard.set(MacDrawingTool.pen.rawValue, forKey: "MindMap.macDrawingTool")
        var topic = Node(text: "Topic with sketch")
        let sketch = Attachment(kind: .drawing, title: "Whiteboard")
        topic.attachments = [sketch]
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        let harness = try await CanvasEventHarness(realDocumentWith: map)
        var closed = false
        defer { if !closed { harness.close() } }
        let model = harness.editor.model
        let sample = DebugDrawing.sample()
        model.attachmentStore.write(sample.dataRepresentation(), to: sketch.fileName)
        try await harness.wait(300)

        let frame = harness.screenFrame(of: topic.id)
        let info = try #require(harness.editor.scene.nodes[topic.id])
        let scale = harness.editor.viewport.scale
        let icon = AttachmentIconRow.iconSize(fontSize: info.appearance.fontSize) * scale
        let point = CGPoint(x: frame.maxX - info.appearance.paddingH * scale - icon / 2, y: frame.midY)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        try await harness.click(point)
        var drawingWindow: NSWindow?
        for _ in 0..<30 where drawingWindow == nil {
            try await harness.wait(100)
            drawingWindow = NSApp.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && pageView(in: $0.contentView) != nil
            }
        }
        let window = try #require(drawingWindow)
        window.setContentSize(CGSize(width: 900, height: 760))
        try await harness.wait(500)
        let page = try #require(pageView(in: window.contentView))
        #expect(window.title == "Whiteboard")
        #expect(page.drawing.strokes.count == sample.strokes.count)
        #expect(page.frame.width == HandwrittenNote.pageWidth)
        #expect(page.frame.height >= sample.bounds.maxY + HandwrittenNote.bottomMargin - 1)
        // The ink is actually drawn (white page + strokes); PNG for a visual check.
        let coverage = try inkCoverage(try #require(window.contentView), writeTo: "drawing-window.png")
        #expect(coverage > 0.005)

        // Mouse drawing: one drag = one PKStroke = one "Draw" step on the document's manager.
        var time = ProcessInfo.processInfo.systemUptime
        try mouse(.leftMouseDown, CGPoint(x: 120, y: 650), in: page, time: time)
        for step in 1...20 {
            time += 0.016
            try mouse(.leftMouseDragged, CGPoint(x: 120 + CGFloat(step) * 20, y: 650 + CGFloat(step % 2) * 40),
                      in: page, time: time)
        }
        try mouse(.leftMouseUp, CGPoint(x: 520, y: 650), in: page, time: time + 0.016)
        try await harness.wait(300)
        let stored = HandwrittenNote.drawing(model.content(of: sketch.id))
        #expect(stored.strokes.count == sample.strokes.count + 1)
        let added = try #require(stored.strokes.last)
        #expect(added.ink.inkType == .pen)
        #expect(abs(added.renderBounds.minX - 120) < 12)
        let documentUndo = try #require(page.documentUndoManager)
        #expect(NSDocumentController.shared.documents.contains { $0.undoManager === documentUndo })
        #expect(documentUndo.undoActionName == "Draw")
        _ = try inkCoverage(try #require(window.contentView), writeTo: "drawing-window-stroke.png")

        // Cmd+Z in the drawing window (DrawingPageView.undo) reverts the stroke.
        page.undo(nil)
        try await harness.wait(300)
        #expect(HandwrittenNote.drawing(model.content(of: sketch.id)).strokes.count == sample.strokes.count)
        #expect(page.drawing.strokes.count == sample.strokes.count)

        // Stroke eraser: dragging across the box removes it (one step).
        UserDefaults.standard.set(MacDrawingTool.eraser.rawValue, forKey: "MindMap.macDrawingTool")
        try await harness.wait(300)
        #expect(page.tool == .eraser)
        try mouse(.leftMouseDown, CGPoint(x: 230, y: 290), in: page, time: time + 1)
        try mouse(.leftMouseDragged, CGPoint(x: 230, y: 302), in: page, time: time + 1.02)
        try mouse(.leftMouseUp, CGPoint(x: 230, y: 310), in: page, time: time + 1.04)
        try await harness.wait(300)
        #expect(HandwrittenNote.drawing(model.content(of: sketch.id)).strokes.count == sample.strokes.count - 1)
        UserDefaults.standard.set(MacDrawingTool.pen.rawValue, forKey: "MindMap.macDrawingTool")

        documentUndo.removeAllActions()
        let document = NSDocumentController.shared.documents.first { $0.undoManager === documentUndo }
        document?.updateChangeCount(.changeCleared)
        harness.close()
        closed = true
        try await harness.wait(800)
        #expect(!window.isVisible)
    }

    @Test func mouseStrokeConversionKeepsPointsAndTiming() throws {
        let points: [(point: CGPoint, time: TimeInterval)] = [(CGPoint(x: 0, y: 0), 10), (CGPoint(x: 50, y: 20), 10.1),
                                                              (CGPoint(x: 100, y: 0), 10.2)]
        let stroke = try #require(DrawingPageView.stroke(from: points, color: .black, width: 3))
        #expect(stroke.path.map(\.location) == points.map(\.point))
        #expect(abs(stroke.path.last!.timeOffset - 0.2) < 0.0001)
        #expect(DrawingPageView.stroke(from: [points[0]], color: .black, width: 3) == nil)
        let image = DrawingPageView.render(PKDrawing(strokes: [stroke]), rect: CGRect(x: 0, y: 0, width: 100, height: 30),
                                           scale: 2)
        #expect(image.size == CGSize(width: 100, height: 30))
    }
}
#endif
