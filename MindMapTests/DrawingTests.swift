import Foundation
import PencilKit
import SwiftUI
import Testing
@testable import MindMap

private func makeUndo() -> UndoManager {
    let undo = UndoManager()
    undo.groupsByEvent = false
    return undo
}

private func drawing(_ model: MindMapModel, _ id: UUID) -> PKDrawing {
    HandwrittenNote.drawing(model.content(of: id))
}

/// One synthetic pen stroke (deterministic points).
private func line(from a: CGPoint, to b: CGPoint, color: DebugInkColor = .black) -> PKStroke {
    DebugDrawing.stroke((0...20).map { i in
        let t = CGFloat(i) / 20
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }, color: color, width: 4)
}

/// Stroke geometry that survives `dataRepresentation()` (control points).
private func signature(_ drawing: PKDrawing) -> [[CGPoint]] {
    drawing.strokes.map { stroke in stroke.path.map(\.location) }
}

/// Handwritten notes (WP5): model ops + undo.
struct DrawingModelTests {
    private func makeModel() -> (MindMapModel, topic: UUID) {
        let topic = Node(text: "Sketches")
        return (MindMapModel(map: MindMap(root: Node(text: "Central", children: [topic]))), topic.id)
    }

    @Test func addDrawingCreatesEmptyPencilKitFile() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: topic, undoManager: undo))
        let attachment = try #require(model.attachment(id))
        #expect(attachment.kind == .drawing)
        #expect(attachment.fileName == "\(id.uuidString).drawing")
        #expect(attachment.title == "Handwritten Note")
        #expect(undo.undoActionName == "Add Handwritten Note")
        let data = try #require(model.content(of: id))
        #expect(try PKDrawing(data: data).strokes.isEmpty)

        undo.undo()
        #expect(model.attachment(id) == nil)
        undo.redo()
        #expect(model.attachment(id) == attachment)
        #expect(model.content(of: id) == data)
        let second = try #require(model.addDrawing(to: topic, undoManager: undo))
        #expect(model.attachment(second)?.title == "Handwritten Note 2")
        #expect(model.addDrawing(to: UUID(), undoManager: undo) == nil)
    }

    @Test func eachDrawBatchIsOneUndoStep() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: topic, undoManager: undo))
        var sketch = PKDrawing()
        sketch.strokes.append(line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 40)))
        let one = sketch
        let start = Date()
        #expect(model.setAttachmentContent(one.dataRepresentation(), for: id, actionName: "Draw", coalescing: false,
                                           undoManager: undo, now: start))
        sketch.strokes.append(line(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 300, y: 90), color: .red))
        // Within the note-typing coalesce interval, but drawings never coalesce.
        #expect(model.setAttachmentContent(sketch.dataRepresentation(), for: id, actionName: "Draw", coalescing: false,
                                           undoManager: undo, now: start.addingTimeInterval(0.5)))
        #expect(undo.undoActionName == "Draw")
        #expect(drawing(model, id).strokes.count == 2)
        #expect(model.attachment(id)?.modifiedAt == start.addingTimeInterval(0.5))

        undo.undo()
        #expect(signature(drawing(model, id)) == signature(one))
        undo.undo()
        #expect(drawing(model, id).strokes.isEmpty)
        #expect(undo.undoActionName == "Add Handwritten Note")
        undo.redo()
        undo.redo()
        #expect(drawing(model, id).strokes.count == 2)
        // Same bytes again: no step.
        #expect(!model.setAttachmentContent(sketch.dataRepresentation(), for: id, actionName: "Draw",
                                            coalescing: false, undoManager: undo))
    }

    @Test func removeAndTopicDeleteUndoRestoreTheDrawing() throws {
        let (model, topic) = makeModel()
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: topic, content: DebugDrawing.sample().dataRepresentation(),
                                               undoManager: undo))
        let bytes = try #require(model.content(of: id))
        #expect(model.removeAttachment(id, undoManager: undo))
        #expect(undo.undoActionName == "Remove Handwritten Note")
        #expect(model.attachment(id) == nil)
        undo.undo()
        #expect(model.content(of: id) == bytes)

        #expect(model.delete(topic, undoManager: undo))
        #expect(model.attachment(id) == nil)
        undo.undo()
        #expect(model.content(of: id) == bytes)
        #expect(signature(drawing(model, id)) == signature(DebugDrawing.sample()))
    }

    @Test func corruptOrMissingDataIsAnEmptyDrawing() {
        #expect(HandwrittenNote.drawing(nil).strokes.isEmpty)
        #expect(HandwrittenNote.drawing(Data()).strokes.isEmpty)
        #expect(HandwrittenNote.drawing(Data("not a drawing".utf8)).strokes.isEmpty)
        #expect(HandwrittenNote.inkBounds(PKDrawing()) == nil)
        #expect(HandwrittenNote.inkBounds(DebugDrawing.sample()) == DebugDrawing.sample().bounds)
    }

    @Test func handwritingCommandAddsThenOpensFullScreen() throws {
        let topic = Node(text: "T")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "R", children: [topic]))))
        editor.undoManager = makeUndo()
        editor.select(topic.id)
        #expect(KeyCommandMap.command(key: KeyEquivalent("d"), modifiers: [.command, .shift], characters: "D")
                == .handwrittenNote)
        #expect(KeyCommandMap.command(key: KeyEquivalent("d"), modifiers: [.command], characters: "d") == nil)
        #expect(!editor.commandState.selectionHasDrawing)
        #expect(editor.perform(.handwrittenNote))
        let sketch = try #require(editor.firstDrawing(of: topic.id))
        #expect(editor.presentedAttachment?.attachmentID == sketch.id)
        #expect(editor.presentedAttachment?.fullScreen == true)
        #expect(editor.model.isDraft(sketch.id))
        editor.presentedAttachment = nil
        #expect(editor.perform(.handwrittenNote))
        #expect(editor.presentedAttachment?.attachmentID == sketch.id)
        #expect(editor.model.drafts(of: topic.id).count == 1)
        #expect(editor.model.setAttachmentContent(DebugDrawing.sample().dataRepresentation(), for: sketch.id,
                                                  actionName: "Draw", coalescing: false, undoManager: editor.undoManager))
        #expect(editor.commandState.selectionHasDrawing)
        #expect(editor.attachments(of: topic.id).count == 1)
        editor.addDrawing(to: topic.id)
        #expect(editor.attachments(of: topic.id).count == 1)
        #expect(editor.model.drafts(of: topic.id).count == 1)
        // Markdown notes still open as a page sheet.
        editor.addNote(to: topic.id)
        #expect(editor.presentedAttachment?.fullScreen == false)
    }
}

/// Drawings through a real package on disk + JSON compatibility.
struct DrawingStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Drawing-\(UUID().uuidString)")
            .appendingPathExtension("mindmap")
    }

    private func save(_ document: MindMapDocument, to url: URL, previous: URL?) throws {
        let snapshot = try document.snapshot(contentType: .mindMap)
        let existing = try previous.map { try FileWrapper(url: $0) }
        let wrapper = try MindMapDocument.package(for: snapshot, existing: existing)
        try wrapper.write(to: url, options: .atomic, originalContentsURL: previous)
    }

    private func open(_ url: URL) throws -> MindMapModel {
        let wrapper = try FileWrapper(url: url)
        let map = try MindMapPackage.read(wrapper)
        return MindMapModel(map: map, attachmentStore: AttachmentStore(package: wrapper,
                                                                       referenced: map.referencedAttachmentFileNames))
    }

    private func attachmentFiles(_ url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("attachments").path)) ?? [])
    }

    @Test func drawingRoundTripsThroughPackageOnDisk() throws {
        let document = MindMapDocument()
        let model = document.model
        let undo = makeUndo()
        let topic = try #require(model.addChild(to: model.root.id, text: "Sketch", undoManager: undo))
        let id = try #require(model.addDrawing(to: topic, undoManager: undo))
        var original = PKDrawing()
        original.strokes.append(line(from: CGPoint(x: 12, y: 30), to: CGPoint(x: 400, y: 260)))
        original.strokes.append(line(from: CGPoint(x: 50, y: 300), to: CGPoint(x: 90, y: 900), color: .blue))
        model.setAttachmentContent(original.dataRepresentation(), for: id, actionName: "Draw", coalescing: false,
                                   undoManager: undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(document, to: url, previous: nil)

        let name = "\(id.uuidString).drawing"
        #expect(attachmentFiles(url) == [name])
        // The file is exactly PKDrawing.dataRepresentation().
        let file = try Data(contentsOf: url.appendingPathComponent("attachments/\(name)"))
        let fromFile = try PKDrawing(data: file)
        #expect(try fromFile == PKDrawing(data: original.dataRepresentation()))
        #expect(signature(fromFile) == signature(original))
        #expect(fromFile.strokes.map(\.ink.inkType) == [.pen, .pen])

        let reopened = try open(url)
        #expect(reopened.map == model.map)
        #expect(reopened.attachment(id)?.kind == .drawing)
        let reloaded = HandwrittenNote.drawing(reopened.content(of: id))
        #expect(signature(reloaded) == signature(original))
        #expect(reloaded.bounds.integral == original.bounds.integral)
        #expect(!reopened.attachmentStore.hasPendingChanges)
    }

    @Test func orphanDrawingIsDroppedOnSaveAndUndoBringsItBack() throws {
        let document = MindMapDocument()
        let model = document.model
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: model.root.id, content: DebugDrawing.sample().dataRepresentation(),
                                               undoManager: undo))
        let urls = [tempURL(), tempURL(), tempURL()]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let name = "\(id.uuidString).drawing"
        try save(document, to: urls[0], previous: nil)
        #expect(attachmentFiles(urls[0]) == [name])

        #expect(model.removeAttachment(id, undoManager: undo))
        try save(document, to: urls[1], previous: urls[0])
        #expect(attachmentFiles(urls[1]).isEmpty)

        undo.undo()
        try save(document, to: urls[2], previous: urls[1])
        #expect(attachmentFiles(urls[2]) == [name])
        let data = try Data(contentsOf: urls[2].appendingPathComponent("attachments/\(name)"))
        #expect(signature(try PKDrawing(data: data)) == signature(DebugDrawing.sample()))
    }

    @Test func drawingAttachmentJSONIsCompatible() throws {
        let node = UUID(), id = UUID()
        // Written by this version: kind + fileName; read back unchanged.
        let json = #"{"formatVersion":1,"root":{"id":"\#(node.uuidString)","text":"T","attachments":[{"id":"\#(id.uuidString)","kind":"drawing","title":"Board","fileName":"\#(id.uuidString).drawing","createdAt":0,"modifiedAt":5}]}}"#
        let map = try MindMapPackage.decode(Data(json.utf8))
        let attachment = try #require(map.root.attachments.first)
        #expect(attachment.kind == .drawing)
        #expect(attachment.fileName == "\(id.uuidString).drawing")
        #expect(attachment.title == "Board")
        #expect(try MindMapPackage.decode(MindMapPackage.encode(map)) == map)
        #expect(map.referencedAttachmentFileNames == ["\(id.uuidString).drawing"])
        // Without dates (hand-written / older writer) it still decodes.
        let minimal = #"{"id":"\#(id.uuidString)","kind":"drawing"}"#
        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(minimal.utf8))
        #expect(decoded.kind == .drawing)
        #expect(decoded.fileName == id.uuidString)
    }
}

/// Endless canvas geometry (iPad and macOS share it). Strokes are never moved.
struct EndlessCanvasGeometryTests {
    private let viewport = CGSize(width: 1194, height: 834)
    /// Ink well outside the original page: left of and above the origin, and taller than a screen.
    static let wideInk = CGRect(x: -900, y: -600, width: 2600, height: 3100)

    @Test func scrollableAreaKeepsAScreenOfRoomAroundPageInkAndView() {
        let visible = CGRect(x: 0, y: 0, width: 1024, height: 700)
        #expect(HandwrittenNote.contentRect(ink: nil, visible: visible) == CGRect(x: -1024, y: -700, width: 3072, height: 2100))
        // Ink approaching (and past) the left/top edge pushes the area out by a screen.
        let ink = CGRect(x: -1500, y: -900, width: 200, height: 200)
        let rect = HandwrittenNote.contentRect(ink: ink, visible: visible)
        #expect(rect.minX == ink.minX - visible.width)
        #expect(rect.minY == ink.minY - visible.height)
        #expect(rect.maxX == HandwrittenNote.pageWidth + visible.width)
        // Scrolling away extends it again (the visible rect is always surrounded by room).
        let far = visible.offsetBy(dx: 5000, dy: 4000)
        let moved = HandwrittenNote.contentRect(ink: ink, visible: far)
        #expect(moved.maxX == far.maxX + far.width)
        #expect(moved.maxY == far.maxY + far.height)
        #expect(moved.contains(ink) && moved.contains(far))
    }

    @Test func openingShowsThePageAsBeforeOrFitsAllTheInk() {
        let page = HandwrittenNote.pageZoom(viewport: viewport)
        // Empty note and a note within the page: the page width fitted from the origin, as before.
        for ink in [nil, DebugDrawing.sample().bounds] {
            let opening = HandwrittenNote.openingView(ink: ink, viewport: viewport)
            #expect(opening.zoom == page)
            #expect(opening.visible.origin == .zero)
        }
        // Ink beyond the page: zoomed out until all of it (plus padding) is visible, centred.
        let ink = Self.wideInk
        let opening = HandwrittenNote.openingView(ink: ink, viewport: viewport)
        #expect(opening.zoom == HandwrittenNote.fitZoom(ink: ink, viewport: viewport))
        #expect(opening.zoom < page)
        #expect(opening.visible.contains(ink.insetBy(dx: -HandwrittenNote.fitPadding + 0.5,
                                                     dy: -HandwrittenNote.fitPadding + 0.5)))
        #expect(abs(opening.visible.midX - ink.midX) < 0.001 && abs(opening.visible.midY - ink.midY) < 0.001)
        #expect(abs(opening.visible.width * opening.zoom - viewport.width) < 0.001)
        // Small ink never opens zoomed in beyond the page fit.
        let word = CGRect(x: 2000, y: 50, width: 60, height: 20)
        #expect(HandwrittenNote.openingView(ink: word, viewport: viewport).zoom == page)
    }

    @Test func zoomGoesOutBeyondAllTheInkAndInGenerously() {
        let page = HandwrittenNote.pageZoom(viewport: viewport)
        #expect(HandwrittenNote.zoomLimits(ink: nil, viewport: viewport)
                == page / HandwrittenNote.zoomOutRoom ... page * HandwrittenNote.maxZoomFactor)
        let limits = HandwrittenNote.zoomLimits(ink: Self.wideInk, viewport: viewport)
        let fit = HandwrittenNote.fitZoom(ink: Self.wideInk, viewport: viewport)
        #expect(limits.lowerBound == fit / HandwrittenNote.zoomOutRoom)
        #expect(limits.contains(HandwrittenNote.openingView(ink: Self.wideInk, viewport: viewport).zoom))
    }
}

#if os(iOS)
import UIKit

/// The canvas's undo manager drops PencilKit's own registrations and
/// forwards undo/redo (after flushing pending strokes) to the document's.
@MainActor
struct DrawingUndoForwarderTests {
    @Test func registrationsAreDroppedAndUndoIsForwarded() throws {
        let document = makeUndo()
        let forwarder = DrawingUndoForwarder()
        forwarder.target = document
        var flushed = 0
        forwarder.willForward = { flushed += 1 }
        final class Box { var value = 0 }
        let box = Box()
        forwarder.registerUndo(withTarget: box) { $0.value = -1 }
        #expect(!document.canUndo)
        #expect(!forwarder.canUndo)

        func set(_ value: Int) {
            let old = box.value
            box.value = value
            document.beginUndoGrouping()
            document.registerUndo(withTarget: box) { _ in set(old) }
            document.setActionName("Draw")
            document.endUndoGrouping()
        }
        set(1)
        #expect(forwarder.canUndo)
        #expect(forwarder.undoActionName == "Draw")
        forwarder.undo()
        #expect(box.value == 0)
        #expect(flushed == 1)
        #expect(forwarder.canRedo)
        forwarder.redo()
        #expect(box.value == 1)
        #expect(flushed == 2)
        #expect(!forwarder.canRedo)

        forwarder.hasPendingChanges = { true }
        #expect(forwarder.canUndo)
        #expect(!forwarder.canRedo)
        let canvas = PencilCanvasView()
        #expect(canvas.undoManager === canvas.forwarder)
    }

    @Test func drawingEditsMarkUIDocumentDirtyAndRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UIDocDrawing-\(UUID().uuidString).mindmap")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MindMapUIDocument(fileURL: url)
        #expect(await document.save(to: url, for: .forCreating))
        let undo = makeUndo()
        document.undoManager = undo
        let id = try #require(document.model.addDrawing(to: document.model.root.id, undoManager: undo))
        #expect(await document.save(to: url, for: .forOverwriting))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!document.hasUnsavedChanges)
        let sample = DebugDrawing.sample()
        document.model.setAttachmentContent(sample.dataRepresentation(), for: id, actionName: "Draw",
                                            coalescing: false, undoManager: undo)
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.hasUnsavedChanges)
        #expect(await document.close())

        let reopened = MindMapUIDocument(fileURL: url)
        #expect(await reopened.open())
        #expect(signature(HandwrittenNote.drawing(reopened.model.content(of: id))) == signature(sample))
        #expect(await reopened.close())
    }
}

/// Apple Pencil in the full-screen handwritten note: the canvas owns the
/// tool picker (selections, PencilKit's double-tap / squeeze), and the map's
/// window-level Pencil interaction stays out of the way while the note is up.
@MainActor
struct PencilNoteInteractionTests {
    /// Landscape iPad Pro 11-inch.
    private static let windowSize = CGSize(width: 1194, height: 834)
    private static let settleTime: TimeInterval = 1

    @Observable final class Cover {
        var isPresented = false
    }

    private struct CoverHost: View {
        let model: MindMapModel
        let id: UUID
        let undo: UndoManager
        @Bindable var cover: Cover

        var body: some View {
            Color.clear.fullScreenCover(isPresented: $cover.isPresented) {
                NavigationStack {
                    PencilCanvas(model: model, attachmentID: id, fileName: model.attachment(id)?.fileName ?? "",
                                 revision: 0, undoManager: undo, fingerDrawing: false, flusher: DrawingFlusher())
                }
            }
        }
    }

    private func makeWindow<Content: View>(_ content: Content) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.windowSize)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        settle()
        return window
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(Self.settleTime)) }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    @available(iOS 18.0, *)
    @Test func openedNoteTakesFocusSoTheToolPickerDrivesTheCanvas() throws {
        let model = MindMapModel(map: MindMap(root: Node(text: "Central")))
        let undo = makeUndo()
        let id = try #require(model.addDrawing(to: model.root.id, undoManager: undo))
        let cover = Cover()
        let window = try makeWindow(CoverHost(model: model, id: id, undo: undo, cover: cover))
        defer { window.isHidden = true }
        cover.isPresented = true
        settle()

        let presented = try #require(window.rootViewController?.presentedViewController)
        let canvas = try #require(views(in: presented.view).compactMap { $0 as? PencilCanvasView }.first)
        let picker = try #require((canvas.delegate as? PencilCanvas.Coordinator)?.toolPicker)
        #expect(canvas.isFirstResponder)
        #expect(picker.isVisible)
        // PencilKit's own Pencil interaction (double-tap / squeeze) exists only for a visible picker.
        let pencilKitInteractions = windows().flatMap { views(in: $0) }.flatMap(\.interactions)
            .compactMap { $0 as? UIPencilInteraction }.filter { !($0.delegate is PencilBridge.BridgeView) }
        #expect(!pencilKitInteractions.isEmpty)

        let eraser = try #require(picker.toolItems.first { $0 is PKToolPickerEraserItem })
        picker.selectedToolItemIdentifier = eraser.identifier
        #expect(canvas.tool is PKEraserTool)
        let pen = try #require(picker.toolItems.first { $0.identifier == PKInkingTool.InkType.pen.rawValue })
        picker.selectedToolItemIdentifier = pen.identifier
        let ink = try #require(canvas.tool as? PKInkingTool)
        #expect(ink.inkType == .pen)

        // Page geometry: the fixed-width page is zoomed to fit the view width.
        #expect(abs(canvas.zoomScale - canvas.bounds.width / HandwrittenNote.pageWidth) < 0.001)
        cover.isPresented = false
        settle()
    }

    /// Fraction of dark pixels of `canvas` inside `rect` (view coordinates), as rendered on screen.
    private func inkCoverage(of canvas: UIView, in rect: CGRect) -> Double {
        let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { _ in
            _ = canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let scale = CGFloat(cg.width) / canvas.bounds.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
                            height: rect.height * scale).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var dark = 0, total = 0
        for y in Int(pixels.minY)..<Int(pixels.maxY) {
            for x in Int(pixels.minX)..<Int(pixels.maxX) {
                let offset = y * cg.bytesPerRow + x * cg.bitsPerPixel / 8
                total += 1
                if Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2]) < 3 * 128 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    /// Endless canvas: an existing note opens with all its ink on screen; the
    /// scrollable area grows left/up (and wherever the user writes) while the
    /// stored strokes keep their coordinates.
    @Test func noteOpensFittedToItsInkAndExtendsLeftAndUpWithoutMovingStrokes() throws {
        let model = MindMapModel(map: MindMap(root: Node(text: "Central")))
        let undo = makeUndo()
        let ink = EndlessCanvasGeometryTests.wideInk
        var sketch = PKDrawing()
        sketch.strokes = [line(from: ink.origin, to: CGPoint(x: ink.maxX, y: ink.minY + 200)),
                          line(from: CGPoint(x: ink.minX + 100, y: ink.maxY), to: CGPoint(x: ink.maxX, y: ink.maxY - 300)),
                          line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 600, y: 140))]
        let id = try #require(model.addDrawing(to: model.root.id, content: sketch.dataRepresentation(), undoManager: undo))
        let cover = Cover()
        let window = try makeWindow(CoverHost(model: model, id: id, undo: undo, cover: cover))
        defer { window.isHidden = true }
        cover.isPresented = true
        settle()

        let presented = try #require(window.rootViewController?.presentedViewController)
        let canvas = try #require(views(in: presented.view).compactMap { $0 as? PencilCanvasView }.first)
        let coordinator = try #require(canvas.delegate as? PencilCanvas.Coordinator)
        // Opens with all the ink on screen, at the fit zoom.
        let opening = HandwrittenNote.openingView(ink: sketch.bounds, viewport: canvas.bounds.size)
        #expect(abs(canvas.zoomScale - opening.zoom) < 0.001)
        #expect(coordinator.visibleRect.insetBy(dx: -1, dy: -1).contains(sketch.bounds))
        #expect(canvas.minimumZoomScale < canvas.zoomScale)
        #expect(canvas.drawing.strokes.allSatisfy { $0.transform == .identity })
        #expect(signature(canvas.drawing) == signature(sketch))
        // Ink left of / above the origin is drawn on screen.
        let zoom = canvas.zoomScale
        let topLeft = CGRect(x: ink.minX * zoom - canvas.contentOffset.x, y: ink.minY * zoom - canvas.contentOffset.y,
                             width: 400 * zoom, height: 60 * zoom)
        #expect(inkCoverage(of: canvas, in: topLeft) > 0.005)

        // Zooming out keeps the visible rect inside the scrollable area.
        canvas.setZoomScale(canvas.minimumZoomScale, animated: false)
        let out = coordinator.visibleRect
        #expect(-canvas.contentInset.left / canvas.zoomScale < out.minX && -canvas.contentInset.top / canvas.zoomScale < out.minY)
        #expect(canvas.contentSize.width / canvas.zoomScale > out.maxX && canvas.contentSize.height / canvas.zoomScale > out.maxY)
        canvas.setZoomScale(opening.zoom, animated: false)

        // Panning to the top-left end of the scrollable area extends it; the view does not jump.
        let before = canvas.contentInset
        let corner = CGPoint(x: -before.left, y: -before.top)
        canvas.contentOffset = corner
        #expect(abs(canvas.contentOffset.x - corner.x) < 1 && abs(canvas.contentOffset.y - corner.y) < 1)
        #expect(canvas.contentInset.left > before.left && canvas.contentInset.top > before.top)
        let shown = coordinator.visibleRect
        #expect(shown.maxX < ink.minX && shown.maxY < ink.minY)

        // Writing there (far left of and above the origin) is stored with its coordinates as drawn.
        let far = line(from: CGPoint(x: shown.minX + 100, y: shown.minY + 100),
                       to: CGPoint(x: shown.minX + 700, y: shown.minY + 160))
        canvas.drawing.strokes.append(far)
        coordinator.flush()
        let stored = HandwrittenNote.drawing(model.content(of: id))
        #expect(signature(stored) == signature(sketch) + signature(PKDrawing(strokes: [far])))
        #expect(stored.strokes.allSatisfy { $0.transform == .identity })
        let farView = CGRect(x: (shown.minX + 100) * zoom - canvas.contentOffset.x,
                             y: (shown.minY + 90) * zoom - canvas.contentOffset.y, width: 600 * zoom, height: 80 * zoom)
        settle()
        #expect(inkCoverage(of: canvas, in: farView) > 0.005)
        #expect(abs(canvas.contentOffset.x - corner.x) < 1 && abs(canvas.contentOffset.y - corner.y) < 1)
        cover.isPresented = false
        settle()
    }

    @Test func mapPencilInteractionIsOffWhileANoteIsPresented() throws {
        let model = MindMapModel(map: MindMap(root: Node(text: "Central")))
        let editor = EditorController(model: model)
        let window = try makeWindow(CanvasView(editor: editor))
        defer { window.isHidden = true }
        let pencil = try #require(window.interactions.compactMap { $0 as? UIPencilInteraction }.first)
        #expect(pencil.isEnabled)

        editor.presentedAttachment = AttachmentRequest(attachmentID: UUID(), fullScreen: true)
        settle()
        #expect(!pencil.isEnabled)

        editor.presentedAttachment = nil
        settle()
        #expect(pencil.isEnabled)
    }
}
#endif

#if os(macOS)
import AppKit

/// macOS handwriting board on the endless canvas: same opening fit and
/// extension as the iPad, strokes untouched.
@MainActor
struct MacDrawingBoardFitTests {
    private static let windowSize = CGSize(width: 900, height: 700)
    private static let settleTime: TimeInterval = 0.5

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(Self.settleTime)) }

    /// Equal up to the clip view's floating-point scroll arithmetic.
    private func isClose(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }

    private func pageView(in view: NSView) -> DrawingPageView? {
        if let page = view as? DrawingPageView { return page }
        return view.subviews.lazy.compactMap { pageView(in: $0) }.first
    }

    @Test func boardOpensFittedToItsInkAndExtendsLeftAndUpWithoutMovingStrokes() throws {
        let ink = EndlessCanvasGeometryTests.wideInk
        var sketch = PKDrawing()
        sketch.strokes = [line(from: ink.origin, to: CGPoint(x: ink.maxX, y: ink.minY + 200)),
                          line(from: CGPoint(x: ink.minX + 100, y: ink.maxY), to: CGPoint(x: ink.maxX, y: ink.maxY - 300))]
        var committed: [Data] = []
        let board = MacDrawingBoard(data: sketch.dataRepresentation(), revision: 0, tool: .pen, inkColor: .black,
                                    undoManager: nil, onCommit: { committed.append($0) })
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.windowSize), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: board)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle()

        let content = try #require(window.contentView)
        let page = try #require(pageView(in: content))
        let scroll = try #require(page.enclosingScrollView)
        let opening = HandwrittenNote.openingView(ink: sketch.bounds, viewport: scroll.contentSize)
        #expect(abs(scroll.magnification - opening.zoom) < 0.001)
        #expect(scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(sketch.bounds))
        #expect(scroll.minMagnification < scroll.magnification)
        #expect(page.bounds.origin == page.frame.origin)
        #expect(page.bounds.minX < ink.minX && page.bounds.minY < ink.minY)
        #expect(signature(page.drawing) == signature(sketch))

        // Scrolling to the top-left end extends the page; the visible part stays where it was put.
        let corner = page.bounds.origin
        scroll.contentView.scroll(to: corner)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(isClose(scroll.documentVisibleRect.origin, corner))
        #expect(page.bounds.minX < corner.x && page.bounds.minY < corner.y)

        // A mouse stroke there keeps the coordinates it was drawn at.
        let shown = scroll.documentVisibleRect
        let start = CGPoint(x: shown.minX + 50, y: shown.minY + 50)
        let far = try #require(DrawingPageView.stroke(from: [(start, 0), (CGPoint(x: start.x + 300, y: start.y + 20), 0.1)],
                                                      color: .black, width: 3))
        var updated = page.drawing
        updated.strokes.append(far)
        page.drawing = updated
        #expect(isClose(scroll.documentVisibleRect.origin, corner))
        page.onCommit?(updated)
        let stored = HandwrittenNote.drawing(try #require(committed.last))
        #expect(signature(stored) == signature(sketch) + signature(PKDrawing(strokes: [far])))
        #expect(stored.strokes.allSatisfy { $0.transform == .identity })
    }
}
#endif
